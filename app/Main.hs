-- |
-- Module      : Main
-- Description : Application entry point — DB migrations, worker spawn, Warp server.
module Main (main) where

import           Control.Concurrent.Async     (async, link)
import           Control.Concurrent.STM
import           Control.Monad                (replicateM_)
import           Control.Monad.Logger         (runStdoutLoggingT)
import qualified Data.ByteString.Char8        as BS8
import qualified Data.Map.Strict              as Map
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as TE
import           Database.Persist.Postgresql  (createPostgresqlPool, runMigration,
                                               runSqlPool)
import           Network.Wai.Handler.Warp       (run)
import           Network.Wai.Handler.WebSockets (websocketsOr)
import qualified Network.WebSockets             as WS
import           System.IO                      (hSetBuffering, stdout, BufferMode(LineBuffering))
import           Data.Int                     (Int64)
import           System.Environment           (lookupEnv)

import qualified Database                     as DB
import           Server                       (servantApp, wsHandler)
import           Types                        (AppState (..), schedulerThread)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | Default number of worker threads.
defaultWorkers :: Int
defaultWorkers = 4

-- | Default port.
defaultPort :: Int
defaultPort = 8080

-- | Default Docker host (TCP).
defaultDockerHost :: Text
defaultDockerHost = "http://localhost:2375"

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    putStrLn "=============================================="
    putStrLn "       CI/CD Engine -- Starting Up...          "
    putStrLn "=============================================="

    -- Read configuration from environment variables.
    connStr   <- maybe "host=localhost port=5432 dbname=cicd user=postgres password=postgres"
                       BS8.pack <$> lookupEnv "DATABASE_URL"
    port      <- maybe defaultPort read <$> lookupEnv "PORT"
    nWorkers  <- maybe defaultWorkers read <$> lookupEnv "WORKERS"
    dockerH   <- maybe defaultDockerHost T.pack <$> lookupEnv "DOCKER_HOST"

    putStrLn $ "  Database:     " <> BS8.unpack connStr
    putStrLn $ "  Port:         " <> show port
    putStrLn $ "  Workers:      " <> show nWorkers
    putStrLn $ "  Docker Host:  " <> T.unpack dockerH

    -- Create PostgreSQL connection pool and run migrations.
    pool <- runStdoutLoggingT $ createPostgresqlPool connStr 10
    runSqlPool (runMigration DB.migrateAll) pool
    putStrLn "  [OK] Database migrations complete."

    -- Initialize shared state.
    queue       <- newTQueueIO
    activeVar   <- newTVarIO (0 :: Int)
    logChannels <- newTVarIO Map.empty

    let appState = AppState
            { asPool          = pool
            , asPipelineQueue = queue
            , asActiveWorkers = activeVar
            , asLogChannels   = logChannels
            , asDockerHost    = dockerH
            }

    -- Spawn scheduler/worker threads.
    replicateM_ nWorkers $ do
        w <- async (schedulerThread appState)
        link w  -- Link so exceptions propagate to the main thread.
    putStrLn $ "  [OK] Spawned " <> show nWorkers <> " scheduler workers."

    -- Build WAI application with WebSocket middleware.
    let app = websocketsOr WS.defaultConnectionOptions (wsMiddleware appState) (servantApp appState)

    putStrLn $ "\n  >>> Server listening on http://localhost:" <> show port
    run port app

-- ---------------------------------------------------------------------------
-- WebSocket Middleware
-- ---------------------------------------------------------------------------

-- | WebSocket middleware that intercepts @\/ws\/logs\/:id@ paths.
wsMiddleware :: AppState -> WS.ServerApp
wsMiddleware env pendingConn = do
    let reqPath  = WS.requestPath (WS.pendingRequest pendingConn)
        pathText = TE.decodeUtf8 reqPath
    case parseWsPath pathText of
        Just pid -> do
            conn <- WS.acceptRequest pendingConn
            WS.withPingThread conn 30 (pure ()) $
                wsHandler env pid conn
        Nothing ->
            WS.rejectRequest pendingConn "Invalid WebSocket path. Use /ws/logs/<pipeline-id>"

-- | Parse a WebSocket path of the form @\/ws\/logs\/<id>@.
parseWsPath :: Text -> Maybe Int64
parseWsPath path =
    case T.splitOn "/" (T.dropWhile (== '/') path) of
        ["ws", "logs", idText] -> readMaybe' (T.unpack idText)
        _                      -> Nothing

readMaybe' :: Read a => String -> Maybe a
readMaybe' s = case reads s of
    [(x, "")] -> Just x
    _         -> Nothing
