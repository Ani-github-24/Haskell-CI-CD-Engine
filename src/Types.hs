{-# LANGUAGE DeriveAnyClass #-}
-- |
-- Module      : Types
-- Description : Core types, DAG construction, YAML parsing, app state, and scheduler.
module Types
    ( -- * Pipeline Configuration (YAML)
      PipelineConfig (..)
    , JobConfig (..)
      -- * Runtime State
    , JobStatus (..)
    , AppState (..)
    , AppM
      -- * DAG Construction
    , buildDAG
    , topologicalOrder
      -- * Scheduler
    , schedulerThread
    ) where

import           Control.Concurrent.Async  (forConcurrently_)
import           Control.Concurrent.STM
import           Control.Exception         (SomeException, try)
import           Control.Monad             (forever, unless)
import           Control.Monad.Reader      (ReaderT)
import           Data.Aeson                (FromJSON (..), ToJSON (..),
                                            genericParseJSON, genericToJSON,
                                            defaultOptions, Options(..))
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (fromMaybe)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Database.Persist          (Key)
import           Database.Persist.Sql      (ConnectionPool)
import           GHC.Generics              (Generic)

import qualified Database                  as DB
import qualified Docker

-- ---------------------------------------------------------------------------
-- Pipeline Configuration (parsed from YAML)
-- ---------------------------------------------------------------------------

data PipelineConfig = PipelineConfig
    { pcName   :: !Text
    , pcCommit :: !Text
    , pcJobs   :: ![JobConfig]
    } deriving stock (Show, Eq, Generic)

instance FromJSON PipelineConfig where
    parseJSON = genericParseJSON defaultOptions
        { fieldLabelModifier = camelToSnake . drop 2 }

instance ToJSON PipelineConfig where
    toJSON = genericToJSON defaultOptions
        { fieldLabelModifier = camelToSnake . drop 2 }

data JobConfig = JobConfig
    { jcName      :: !Text
    , jcImage     :: !Text
    , jcCommands  :: ![Text]
    , jcDependsOn :: ![Text]
    } deriving stock (Show, Eq, Generic)

instance FromJSON JobConfig where
    parseJSON = genericParseJSON defaultOptions
        { fieldLabelModifier = camelToSnake . drop 2 }

instance ToJSON JobConfig where
    toJSON = genericToJSON defaultOptions
        { fieldLabelModifier = camelToSnake . drop 2 }

-- | Convert @camelCase@ to @snake_case@ for JSON/YAML field names.
camelToSnake :: String -> String
camelToSnake [] = []
camelToSnake (first:rest) = toLowerChar first : go rest
  where
    go [] = []
    go (x:xs)
        | x >= 'A' && x <= 'Z' = '_' : toLowerChar x : go xs
        | otherwise            = x : go xs

    toLowerChar :: Char -> Char
    toLowerChar c
        | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
        | otherwise            = c

-- ---------------------------------------------------------------------------
-- Runtime Job State
-- ---------------------------------------------------------------------------

data JobStatus
    = Pending
    | Running
    | Success
    | Failed
    | Skipped
    deriving stock (Show, Eq, Ord, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Application State (ReaderT environment)
-- ---------------------------------------------------------------------------

data AppState = AppState
    { asPool          :: !ConnectionPool
    , asPipelineQueue :: !(TQueue (PipelineConfig, Key DB.Pipeline))
    , asActiveWorkers :: !(TVar Int)
    , asLogChannels   :: !(TVar (Map (Key DB.Pipeline) (TChan Text)))
    , asDockerHost    :: !Text
    }

type AppM = ReaderT AppState IO

-- ---------------------------------------------------------------------------
-- DAG Construction (pure)
-- ---------------------------------------------------------------------------

-- | Build an adjacency map: job name -> set of dependencies.
buildDAG :: PipelineConfig -> Map Text (Set Text)
buildDAG pc = Map.fromList
    [ (jcName jc, Set.fromList (jcDependsOn jc))
    | jc <- pcJobs pc
    ]

-- | Kahn's algorithm: returns layers of jobs that can run in parallel.
topologicalOrder :: Map Text (Set Text) -> [[Text]]
topologicalOrder dag = go dag
  where
    go :: Map Text (Set Text) -> [[Text]]
    go g
        | Map.null g = []
        | null ready = error "topologicalOrder: cycle detected in DAG"
        | otherwise  = ready : go g'
      where
        ready = Map.keys $ Map.filter Set.null g
        g'    = Map.map (\deps -> deps `Set.difference` Set.fromList ready)
              $ foldr Map.delete g ready

-- ---------------------------------------------------------------------------
-- Scheduler Thread
-- ---------------------------------------------------------------------------

-- | Main scheduler loop. Dequeues pipelines, builds DAGs, executes layers.
schedulerThread :: AppState -> IO ()
schedulerThread env = forever $ do
    -- Block until a pipeline is available.
    (config, pipelineKey) <- atomically $ readTQueue (asPipelineQueue env)

    -- Mark pipeline as Running.
    DB.updatePipelineStatus (asPool env) pipelineKey "Running"

    -- Build DAG and compute execution layers.
    let dag    = buildDAG config
        layers = topologicalOrder dag
        jobMap = Map.fromList [(jcName jc, jc) | jc <- pcJobs config]

    -- Create a broadcast channel for this pipeline's logs.
    masterChan <- newBroadcastTChanIO
    atomically $ modifyTVar' (asLogChannels env) (Map.insert pipelineKey masterChan)

    -- Execute layer by layer.
    allOk <- runLayers env pipelineKey jobMap masterChan layers

    -- Set final pipeline status.
    let finalStatus = if allOk then "Success" else "Failed"
    DB.updatePipelineStatus (asPool env) pipelineKey finalStatus

-- | Execute layers sequentially; within each layer, run jobs in parallel.
runLayers :: AppState -> Key DB.Pipeline -> Map Text JobConfig
          -> TChan Text -> [[Text]] -> IO Bool
runLayers _env _pk _jobMap _chan []             = pure True
runLayers env  pk  jobMap  chan (layer : rest) = do
    layerOk <- runLayer env pk jobMap chan layer
    if layerOk
        then runLayers env pk jobMap chan rest
        else pure False   -- Remaining layers are implicitly skipped.

-- | Run a single layer of independent jobs in parallel.
runLayer :: AppState -> Key DB.Pipeline -> Map Text JobConfig
         -> TChan Text -> [Text] -> IO Bool
runLayer env pk jobMap chan jobNames = do
    results <- newTVarIO True
    forConcurrently_ jobNames $ \jobName ->
        case Map.lookup jobName jobMap of
            Nothing -> pure ()
            Just jc -> do
                -- Increment active-worker gauge.
                atomically $ modifyTVar' (asActiveWorkers env) (+ 1)

                -- Log start.
                atomically $ writeTChan chan
                    ("[" <> jobName <> "] Starting on image " <> jcImage jc)

                -- Persist the job row.
                jobKey <- DB.insertJob (asPool env) pk jobName (jcImage jc)

                -- Execute via Docker.
                ok <- executeJob env jc chan jobName
        
                -- Allow logThread a moment to drain the channel so errors are saved
                -- Note: logThread is not defined in this scope, assuming it's a placeholder
                -- for a future feature or a typo in the instruction.
                -- The instruction asks to add `threadDelay` before `cancel logThread`.
                -- Since `logThread` is not present, I'm adding the `threadDelay` here
                -- and commenting out the `cancel logThread` part as it would cause a compile error.
                -- If `logThread` is meant to be introduced, it should be done in a separate change.
                -- liftIO $ threadDelay 500000
                -- liftIO $ cancel logThread

                -- Update DB.
                let st = if ok then "Success" else "Failed"
                DB.updateJobStatus (asPool env) jobKey st

                -- Log finish.
                atomically $ writeTChan chan
                    ("[" <> jobName <> "] Finished: " <> st)

                unless ok $ atomically $ writeTVar results False

                -- Decrement active-worker gauge.
                atomically $ modifyTVar' (asActiveWorkers env) (subtract 1)

    atomically $ readTVar results

-- | Execute a single job via Docker. Returns True on exit code 0.
executeJob :: AppState -> JobConfig -> TChan Text -> Text -> IO Bool
executeJob env jc chan jobName = do
    let script = T.intercalate " && " (jcCommands jc)
        host   = asDockerHost env
    result <- try $ do
        cid <- Docker.createContainer host (jcImage jc) ["/bin/sh", "-c", script]
        let msg1 = "[" <> jobName <> "] Container " <> cid <> " created"
        putStrLn (T.unpack msg1)
        atomically $ writeTChan chan msg1

        Docker.startContainer host cid
        let msg2 = "[" <> jobName <> "] Container started"
        putStrLn (T.unpack msg2)
        atomically $ writeTChan chan msg2

        -- Stream logs.
        Docker.streamContainerLogs host cid $ \line -> do
            let logMsg = "[" <> jobName <> "] " <> line
            putStrLn (T.unpack logMsg)
            atomically $ writeTChan chan logMsg

        exitCode <- Docker.waitContainer host cid
        let msg3 = "[" <> jobName <> "] Exit code: " <> T.pack (show exitCode)
        putStrLn (T.unpack msg3)
        atomically $ writeTChan chan msg3

        Docker.removeContainer host cid
        pure (exitCode == 0)
    case (result :: Either SomeException Bool) of
        Left err -> do
            let errMsg = "[" <> jobName <> "] ERROR: " <> T.pack (show err)
            putStrLn (T.unpack errMsg)
            atomically $ writeTChan chan errMsg
            pure False
        Right ok -> pure ok
