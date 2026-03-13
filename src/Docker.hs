-- |
-- Module      : Docker
-- Description : Docker Engine HTTP API client using http-conduit.
--
-- Communicates with the Docker daemon over TCP (or Unix socket on Linux)
-- to manage container lifecycle: create, start, attach (logs), wait, remove.
module Docker
    ( createContainer
    , startContainer
    , streamContainerLogs
    , waitContainer
    , removeContainer
    ) where

import           Data.Aeson             (FromJSON (..), ToJSON (..), object,
                                         withObject, (.:), (.=))
import qualified Data.Aeson             as Aeson
import           Data.ByteString        (ByteString)
import qualified Data.ByteString.Char8  as BS8
import qualified Data.ByteString.Lazy   as LBS
import           Data.Text              (Text)
import qualified Data.Text              as T
import           Network.HTTP.Client    (Manager, Request (..),
                                         RequestBody (..), Response (..),
                                         brRead, httpLbs, newManager,
                                         parseRequest, responseBody,
                                         responseStatus, withResponse,
                                         defaultManagerSettings)
import           Network.HTTP.Types     (statusCode)

-- ---------------------------------------------------------------------------
-- Docker API Data Types
-- ---------------------------------------------------------------------------

-- | Request body for @POST \/containers\/create@.
data CreateContainerReq = CreateContainerReq
    { ccrImage :: !Text
    , ccrCmd   :: ![Text]
    } deriving stock (Show)

instance ToJSON CreateContainerReq where
    toJSON CreateContainerReq{..} = object
        [ "Image" .= ccrImage
        , "Cmd"   .= ccrCmd
        , "AttachStdout" .= True
        , "AttachStderr" .= True
        , "Tty"  .= False
        ]

-- | Response from @POST \/containers\/create@.
newtype CreateContainerResp = CreateContainerResp { ccrId :: Text }
    deriving stock (Show)

instance FromJSON CreateContainerResp where
    parseJSON = withObject "CreateContainerResp" $ \o ->
        CreateContainerResp <$> o .: "Id"

-- | Response from @POST \/containers\/{id}\/wait@.
newtype WaitContainerResp = WaitContainerResp { wcrStatusCode :: Int }
    deriving stock (Show)

instance FromJSON WaitContainerResp where
    parseJSON = withObject "WaitContainerResp" $ \o ->
        WaitContainerResp <$> o .: "StatusCode"

-- ---------------------------------------------------------------------------
-- HTTP Helper
-- ---------------------------------------------------------------------------

-- | Get a plain HTTP manager (Docker API is typically unencrypted over
--   Unix socket or localhost TCP).
getManager :: IO Manager
getManager = newManager defaultManagerSettings

apiVersion :: Text
apiVersion = "v1.44"

-- | Build a request to the Docker daemon.
dockerRequest :: Text -> String -> IO Request
dockerRequest host path = do
    let fullUrl = T.unpack host <> "/" <> T.unpack apiVersion <> path
    req <- parseRequest fullUrl
    pure req
        { requestHeaders = [("Content-Type", "application/json")]
        }

-- ---------------------------------------------------------------------------
-- Container Lifecycle
-- ---------------------------------------------------------------------------

-- | Create a new container. Returns the container ID.
--
-- @POST \/containers\/create@
createContainer :: Text -> Text -> [Text] -> IO Text
createContainer host image cmd = do
    mgr <- getManager
    initReq <- dockerRequest host "/containers/create"
    let body = Aeson.encode $ CreateContainerReq image cmd
        req  = initReq
            { method      = "POST"
            , requestBody = RequestBodyLBS body
            }
    resp <- httpLbs req mgr
    let sc = statusCode (responseStatus resp)
    if sc == 201
        then case Aeson.decode (responseBody resp) of
            Just (CreateContainerResp cid) -> pure cid
            Nothing -> fail "Failed to parse container create response"
        else fail $ "Docker create failed with status " <> show sc
                 <> ": " <> BS8.unpack (LBS.toStrict $ responseBody resp)

-- | Start a created container.
--
-- @POST \/containers\/{id}\/start@
startContainer :: Text -> Text -> IO ()
startContainer host cid = do
    mgr <- getManager
    initReq <- dockerRequest host ("/containers/" <> T.unpack cid <> "/start")
    let req = initReq { method = "POST" }
    resp <- httpLbs req mgr
    let sc = statusCode (responseStatus resp)
    -- 204 = started, 304 = already started
    if sc `elem` [204, 304]
        then pure ()
        else fail $ "Docker start failed with status " <> show sc

-- | Stream container logs line by line, invoking a callback for each line.
--
-- @GET \/containers\/{id}\/logs?follow=true&stdout=true&stderr=true@
streamContainerLogs :: Text -> Text -> (Text -> IO ()) -> IO ()
streamContainerLogs host cid callback = do
    mgr <- getManager
    initReq <- dockerRequest host
        ("/containers/" <> T.unpack cid <> "/logs?follow=true&stdout=true&stderr=true")
    let req = initReq { method = "GET" }
    withResponse req mgr $ \resp -> do
        let loop :: IO ()
            loop = do
                chunk <- brRead (responseBody resp)
                if BS8.null chunk
                    then pure ()
                    else do
                        -- Docker multiplexed stream has 8-byte header per frame.
                        -- We strip the header and split on newlines.
                        let cleaned = stripDockerHeader chunk
                            lns     = filter (not . BS8.null) $ BS8.lines cleaned
                        mapM_ (callback . decodeUtf8Lenient) lns
                        loop
        loop

-- | Strip the 8-byte Docker stream header from a frame.
stripDockerHeader :: ByteString -> ByteString
stripDockerHeader bs
    | BS8.length bs > 8 = BS8.drop 8 bs
    | otherwise         = bs

-- | Lenient UTF-8 decode for log bytes.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = T.pack . BS8.unpack

-- | Block until the container exits. Returns the exit code.
--
-- @POST \/containers\/{id}\/wait@
waitContainer :: Text -> Text -> IO Int
waitContainer host cid = do
    mgr <- getManager
    initReq <- dockerRequest host ("/containers/" <> T.unpack cid <> "/wait")
    let req = initReq { method = "POST" }
    resp <- httpLbs req mgr
    case Aeson.decode (responseBody resp) of
        Just (WaitContainerResp code) -> pure code
        Nothing -> fail "Failed to parse wait response"

-- | Remove a container (force).
--
-- @DELETE \/containers\/{id}?force=true@
removeContainer :: Text -> Text -> IO ()
removeContainer host cid = do
    mgr <- getManager
    initReq <- dockerRequest host ("/containers/" <> T.unpack cid <> "?force=true")
    let req = initReq { method = "DELETE" }
    _ <- httpLbs req mgr
    pure ()
