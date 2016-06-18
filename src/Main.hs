{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent
import           Control.Monad             (forever)
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as C
import qualified Data.ByteString.Lazy      as BL
import Data.Maybe
import           Data.String
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as TE
import           Haskakafka
import           Haskakafka.InternalSetup
import           Network.HTTP.Types
import           Network.HTTP.Types.Header ()
import           Network.Wai
import           Network.Wai.Handler.Warp  (run)

producer
  :: Haskakafka.InternalSetup.ConfigOverrides
     -> Haskakafka.InternalSetup.ConfigOverrides
     -> B.ByteString
     -> Chan B.ByteString
     -> IO a
producer kafkaConfig topicConfig topicName channel =
  withKafkaProducer kafkaConfig topicConfig
    "broker2:9092" (C.unpack topicName)
    $ \_ topic ->  forever $ do
        payload <- readChan channel
        produceMessage topic KafkaUnassignedPartition
          $ KafkaProduceMessage payload

startProducerThread
    :: Haskakafka.InternalSetup.ConfigOverrides
     -> Haskakafka.InternalSetup.ConfigOverrides
     -> B.ByteString
     -> IO (B.ByteString, Chan B.ByteString)
startProducerThread kafkaConfig topicConfig topic = do
  C.putStrLn $ B.append "Starting producer client for topic: " topic
  channel <- newChan
  _ <- forkIO $ producer kafkaConfig topicConfig topic channel
  return (topic, channel)

main :: IO ()
main = do
  let
    kafkaConfig = [("socket.timeout.ms", "50000")]
    topicConfig = [("request.timeout.ms", "50000")]
    topics      = ["a","b","c", "d"]
    path        = "/tracking"
  channels <- mapM (startProducerThread kafkaConfig topicConfig) topics
  putStrLn "Starting server on: http://localhost:8080/"
  run 8080 $ app jsonFromQueryString topicFromHost path channels

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

pushPayload
  :: Maybe (Chan C.ByteString)
     -> C.ByteString -> C.ByteString -> IO Response
pushPayload (Just channel) payload _ = do
  _ <- writeChan channel payload
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
