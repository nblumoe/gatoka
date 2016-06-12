{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent
import           Control.Monad             (forever)
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as C
import qualified Data.ByteString.Lazy      as BL
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

startProducer
    :: Haskakafka.InternalSetup.ConfigOverrides
     -> Haskakafka.InternalSetup.ConfigOverrides
     -> B.ByteString
     -> IO (B.ByteString, Chan B.ByteString)
startProducer kafkaConfig topicConfig topic = do
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
  channels <- mapM (startProducer kafkaConfig topicConfig) topics
  putStrLn "Starting server on: http://localhost:8080/"
  run 8080 $ app jsonFromRequest channels

app
  :: (Request -> B.ByteString)
  -> [(B.ByteString, Chan B.ByteString)]
  -> Application
app payloadFromRequest producerChannels request respond
  | Just channel <- maybeChannel = do
      _ <- writeChan channel payload
      respond $ messageProduced $ BL.fromStrict payload
  | Nothing <- maybeChannel = do
      respond $ topicNotFound $ BL.fromStrict topic
  | otherwise  = respond notFound
  where topic = TE.encodeUtf8 $ head $ pathInfo request -- make topic finding function plugable
        maybeChannel = lookup topic producerChannels
        payload = payloadFromRequest request

-- Payload handling

jsonFromRequest :: Request -> B.ByteString
jsonFromRequest request = B.concat ["{", query_items, "}"]
  where query_items = B.intercalate ", " $ map formatQueryItem $ queryString request

formatQueryItem :: QueryItem -> B.ByteString
formatQueryItem ("", _) = ""
formatQueryItem (k, Nothing) = B.append k ": undefined"
formatQueryItem (k, Just v)
  | v == "" = B.append k ": undefined"
  | otherwise = B.concat [k, ": ",  v]

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
