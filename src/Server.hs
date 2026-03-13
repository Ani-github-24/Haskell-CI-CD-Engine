-- |
-- Module      : Server
-- Description : Servant API definition, route handlers, and WebSocket log streaming.
module Server
    ( API
    , apiServer
    , servantApp
    , wsHandler
    ) where

import           Control.Concurrent.STM
import           Control.Monad.IO.Class  (liftIO)
import           Data.Aeson              (ToJSON (..), object, (.=))
import qualified Data.Map.Strict         as Map
import           Data.Proxy              (Proxy (..))
import           Data.Text               (Text)
import qualified Data.Text               as T
import           Data.Int                (Int64)
import           Database.Persist        (Entity (..))
import           Database.Persist.Sql    (Key, toSqlKey)
import           Lucid                   (Html)
import           Network.Wai             (Application)
import qualified Network.WebSockets      as WS
import           Servant
import           Servant.HTML.Lucid      (HTML)

import qualified Database                as DB
import           Types                   (AppState (..), PipelineConfig (..))
import qualified UI

-- ---------------------------------------------------------------------------
-- API Type
-- ---------------------------------------------------------------------------

-- | The REST API served by Servant.
-- WebSocket is handled separately via WAI middleware (see Main.hs).
type API =
         -- GET / — Dashboard
         Get '[HTML] (Html ())

         -- GET /pipeline/:id — Pipeline detail
    :<|> "pipeline" :> Capture "id" Int64 :> Get '[HTML] (Html ())

         -- POST /webhook — Trigger a new pipeline
    :<|> "webhook" :> ReqBody '[JSON] PipelineConfig :> Post '[JSON] WebhookResp

         -- GET /metrics — Prometheus metrics
    :<|> "metrics" :> Get '[PlainText] Text

-- ---------------------------------------------------------------------------
-- Response Types
-- ---------------------------------------------------------------------------

newtype WebhookResp = WebhookResp { wrMessage :: Text }
    deriving stock (Show)

instance ToJSON WebhookResp where
    toJSON (WebhookResp msg) = object ["message" .= msg]

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

-- | Dashboard handler: fetch recent pipelines and render HTML.
dashboardHandler :: AppState -> Handler (Html ())
dashboardHandler env = liftIO $ do
    pipelines <- DB.getRecentPipelines (asPool env) 50
    pure $ UI.dashboardPage pipelines

-- | Pipeline detail handler.
pipelineDetailHandler :: AppState -> Int64 -> Handler (Html ())
pipelineDetailHandler env pid = do
    let pk = toSqlKey pid :: Key DB.Pipeline
    mPipeline <- liftIO $ DB.getPipelineById (asPool env) pk
    case mPipeline of
        Nothing -> throwError err404
        Just pe -> do
            jobs <- liftIO $ DB.getJobsForPipeline (asPool env) pk
            let wsPath = "/ws/logs/" <> T.pack (show pid)
            pure $ UI.pipelineDetailPage pe jobs wsPath

-- | Webhook handler: accept a pipeline config, persist it, enqueue for execution.
webhookHandler :: AppState -> PipelineConfig -> Handler WebhookResp
webhookHandler env config = liftIO $ do
    pk <- DB.insertPipeline (asPool env) (pcName config) (pcCommit config)
    atomically $ writeTQueue (asPipelineQueue env) (config, pk)
    pure $ WebhookResp "Pipeline enqueued"

-- | Metrics handler: return Prometheus-formatted text.
metricsHandler :: AppState -> Handler Text
metricsHandler env = liftIO $ do
    active <- atomically $ readTVar (asActiveWorkers env)
    -- TQueue has no O(1) length; we report 0 for pending and rely on the gauge.
    -- A production system would maintain a separate TVar counter.
    pure $ UI.metricsText 0 active

-- ---------------------------------------------------------------------------
-- WebSocket Handler (called from WAI middleware in Main)
-- ---------------------------------------------------------------------------

-- | WebSocket handler: stream live logs for a given pipeline ID.
wsHandler :: AppState -> Int64 -> WS.Connection -> IO ()
wsHandler env pid conn = do
    let pk = toSqlKey pid :: Key DB.Pipeline
    channels <- atomically $ readTVar (asLogChannels env)
    case Map.lookup pk channels of
        Nothing -> do
            WS.sendTextData conn ("No active log stream for this pipeline." :: Text)
        Just masterChan -> do
            -- Duplicate the broadcast channel to get our own read end.
            readChan <- atomically $ dupTChan masterChan
            -- Stream log lines as HTMX-compatible HTML snippets.
            let loop :: IO ()
                loop = do
                    line <- atomically $ readTChan readChan
                    let htmlChunk = "<div id=\"log-stream\" hx-swap-oob=\"beforeend\">"
                                 <> "<p class=\"text-gray-300\">" <> escapeHtml line <> "</p>"
                                 <> "</div>"
                    WS.sendTextData conn htmlChunk
                    loop
            loop

-- | Minimal HTML escaping for log lines.
escapeHtml :: Text -> Text
escapeHtml = T.replace "<" "&lt;" . T.replace ">" "&gt;" . T.replace "&" "&amp;"

-- ---------------------------------------------------------------------------
-- Server Wiring
-- ---------------------------------------------------------------------------

-- | Servant server for the REST API.
apiServer :: AppState -> Server API
apiServer env =
         dashboardHandler env
    :<|> pipelineDetailHandler env
    :<|> webhookHandler env
    :<|> metricsHandler env

-- | WAI Application for the REST API (without WebSocket).
--   Main.hs wraps this with WebSocket middleware.
servantApp :: AppState -> Application
servantApp env = serve (Proxy :: Proxy API) (apiServer env)
