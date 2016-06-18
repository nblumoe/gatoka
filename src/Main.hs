{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent
import           Control.Monad             (forever)
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as C
import qualified Data.ByteString.Lazy      as BL
import           Data.Maybe
import           Data.String
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as TE
import           Data.Word (Word16)
import qualified Data.Yaml.Config          as Y
import           Haskakafka
import           Haskakafka.InternalSetup
import           Network.HTTP.Types
import           Network.HTTP.Types.Header ()
import           Network.Wai
import           Network.Wai.Handler.Warp  (run)


producer ::
  Y.Config
  -> ConfigOverrides
  -> ConfigOverrides
  -> C.ByteString
  -> Chan C.ByteString
  -> IO a
producer brokerConfig kafkaConfig topicConfig topicName channel =
  let
    host = Y.lookupDefault "host" "localhost" brokerConfig
    port = Y.lookupDefault "port" 9021 brokerConfig :: Word16
  in
    withKafkaProducer kafkaConfig topicConfig
      (host ++ ":" ++ show port) (C.unpack topicName)
      $ \_ topic ->  forever $ do
          payload <- getChanContents channel
          produceMessageBatch topic KafkaUnassignedPartition
            $ map KafkaProduceMessage payload

startProducerThread ::
  Y.Config
  -> ConfigOverrides
  -> ConfigOverrides
  -> C.ByteString
  -> IO (C.ByteString, Chan C.ByteString)
startProducerThread brokerConfig kafkaConfig topicConfig topic = do
  C.putStrLn $ B.append "Starting producer client for topic: " topic
  channel <- newChan
  _ <- forkIO $ producer brokerConfig kafkaConfig topicConfig topic channel
  return (topic, channel)

main :: IO ()
main = do
  config <- Y.load "./config/gatoka.yml"
  serverConfig <- Y.subconfig "server" config
  brokerConfig <- Y.subconfig "broker" config
  let
    port        = Y.lookupDefault "port" 8080 serverConfig
    topics      = Y.lookupDefault "topics" ["dummy"] serverConfig :: [String]
    path        = Y.lookupDefault "path" "/" serverConfig :: String
    kafkaConfig = [("socket.timeout.ms", "50000")]
    topicConfig = [("request.timeout.ms", "50000")]
  channels <- mapM (startProducerThread brokerConfig kafkaConfig topicConfig . C.pack) topics
  putStrLn $ "Starting server on: http://localhost:" ++ show port
  run port $ app jsonFromQueryString topicFromPathRoot (C.pack path) channels

app
  :: (Request -> B.ByteString)
  -> (Request -> B.ByteString)
  -> B.ByteString
  -> [(B.ByteString, Chan B.ByteString)]
  -> Application
app payloadFromRequest topicFromRequest path producerChannels request respond
  | path == rawPathInfo request = pushPayload maybeChannel payload topic >>= respond
  | otherwise                   = respond notFound
  where topic        = topicFromRequest request
        maybeChannel = lookup topic producerChannels
        payload      = payloadFromRequest request

-- some stripped down apps for testing purposes
rawApp channel _ respond = pushPayload channel "raw-payload" "raw" >>= respond
dummyApp _ respond = respond notFound

pushPayload
  :: Maybe (Chan C.ByteString)
     -> C.ByteString -> C.ByteString -> IO Response
pushPayload (Just channel) payload _ = do
  _ <- forkIO $ writeChan channel payload
  return $ messageProduced $ BL.fromStrict payload
pushPayload Nothing _ topic = return $ topicNotFound $ BL.fromStrict topic

-- Response handling

defaultHeader :: [(HeaderName, B.ByteString)]
defaultHeader = [(hContentType, "text/plain")]

messageProduced :: BL.ByteString -> Response
messageProduced = responseLBS
  status200
  defaultHeader

topicNotFound :: BL.ByteString -> Response
topicNotFound topic = responseLBS
  status400
  defaultHeader
  $ BL.append "400 - Topic not found: " topic

notFound :: Response
notFound = responseLBS
  status404
  defaultHeader
  "404 - Not Found"

-- the following will be provided by the calling application / library

-- Topic extracion
topicFromPathRoot :: Request -> C.ByteString
topicFromPathRoot request = TE.encodeUtf8 $ head $ pathInfo request

topicFromHost :: Request -> C.ByteString
topicFromHost request = C.takeWhile (/= '.') $ fromMaybe "" $ requestHeaderHost request

-- Payload handling
jsonFromQueryString :: Request -> B.ByteString
jsonFromQueryString request = B.concat ["{", query_items, "}"]
  where query_items = B.intercalate ", " $ map formatQueryItem $ queryString request

formatQueryItem :: QueryItem -> B.ByteString
formatQueryItem ("", _) = ""
formatQueryItem (k, Nothing) = B.append k ": undefined"
formatQueryItem (k, Just v)
  | v == "" = B.append k ": undefined"
  | otherwise = B.concat [k, ": ",  v]
