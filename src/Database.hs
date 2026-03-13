{-# LANGUAGE DerivingStrategies #-}
-- |
-- Module      : Database
-- Description : Persistent models, migrations, and query helpers for the CI/CD engine.
--
-- This is a "leaf" module with no internal dependencies — other modules
-- import 'Pipeline', 'Job', and the query helpers from here.
module Database
    ( -- * Models
      Pipeline (..)
    , Job (..)
    , EntityField (..)
    , Unique (..)
    , Key (..)
      -- * Migrations
    , migrateAll
      -- * Helpers
    , runDBWith
    , insertPipeline
    , updatePipelineStatus
    , getRecentPipelines
    , getPipelineById
    , getJobsForPipeline
    , insertJob
    , updateJobStatus
    ) where

import           Control.Monad.IO.Class   (MonadIO, liftIO)
import           Data.Text                (Text)
import           Data.Time                (UTCTime, getCurrentTime)
import           Database.Persist
import           Database.Persist.Postgresql
import           Database.Persist.TH

-- ---------------------------------------------------------------------------
-- Persistent Schema
-- ---------------------------------------------------------------------------

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|

Pipeline
    name        Text
    commitHash  Text
    status      Text
    createdAt   UTCTime
    deriving Show Eq

Job
    pipelineId  PipelineId
    name        Text
    dockerImage Text
    status      Text
    logOutput   Text  Maybe
    startedAt   UTCTime  Maybe
    finishedAt  UTCTime  Maybe
    deriving Show Eq

|]

-- ---------------------------------------------------------------------------
-- Pool-based DB Runner
-- ---------------------------------------------------------------------------

-- | Execute a database action given a connection pool.
runDBWith :: MonadIO m => ConnectionPool -> SqlPersistT IO a -> m a
runDBWith pool action = liftIO $ runSqlPool action pool

-- ---------------------------------------------------------------------------
-- Query Helpers
-- ---------------------------------------------------------------------------

-- | Insert a new pipeline record, returning its key.
insertPipeline :: MonadIO m => ConnectionPool -> Text -> Text -> m (Key Pipeline)
insertPipeline pool name' commit' = do
    now <- liftIO getCurrentTime
    runDBWith pool $ insert $ Pipeline name' commit' "Pending" now

-- | Update a pipeline's status.
updatePipelineStatus :: MonadIO m => ConnectionPool -> Key Pipeline -> Text -> m ()
updatePipelineStatus pool pk status' =
    runDBWith pool $ update pk [PipelineStatus =. status']

-- | Fetch the most recent N pipelines, ordered by creation time descending.
getRecentPipelines :: MonadIO m => ConnectionPool -> Int -> m [Entity Pipeline]
getRecentPipelines pool n =
    runDBWith pool $ selectList [] [Desc PipelineCreatedAt, LimitTo n]

-- | Fetch a single pipeline by ID.
getPipelineById :: MonadIO m => ConnectionPool -> Key Pipeline -> m (Maybe (Entity Pipeline))
getPipelineById pool pk =
    runDBWith pool $ getEntity pk

-- | Fetch all jobs for a given pipeline, ordered by name.
getJobsForPipeline :: MonadIO m => ConnectionPool -> Key Pipeline -> m [Entity Job]
getJobsForPipeline pool pk =
    runDBWith pool $ selectList [JobPipelineId ==. pk] [Asc JobName]

-- | Insert a new job record.
insertJob :: MonadIO m => ConnectionPool -> Key Pipeline -> Text -> Text -> m (Key Job)
insertJob pool pk name' image' = do
    now <- liftIO getCurrentTime
    runDBWith pool $ insert $ Job pk name' image' "Pending" Nothing (Just now) Nothing

-- | Update a job's status and set finishedAt timestamp.
updateJobStatus :: MonadIO m => ConnectionPool -> Key Job -> Text -> m ()
updateJobStatus pool jk status' = do
    now <- liftIO getCurrentTime
    runDBWith pool $ update jk [JobStatus =. status', JobFinishedAt =. Just now]
