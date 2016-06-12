{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent
import           Control.Monad             (forever)
import qualified Data.ByteString           as B
import qualified Data.ByteString.Lazy      as BL
import           Data.String
import qualified Data.Text as T
import           Haskakafka
import           Haskakafka.InternalSetup
import           Network.HTTP.Types
import           Network.HTTP.Types.Header ()
import           Network.Wai
import           Network.Wai.Handler.Warp  (run)

producer
  :: Haskakafka.InternalSetup.ConfigOverrides
     -> Haskakafka.InternalSetup.ConfigOverrides
     -> String
     -> Chan B.ByteString
     -> IO a
producer kafkaConfig topicConfig topicName channel =
  withKafkaProducer kafkaConfig topicConfig
    "broker2:9092" topicName
    $ \_ topic ->  forever $ do
        payload <- readChan channel
        produceMessage topic KafkaUnassignedPartition
          $ KafkaProduceMessage payload

startProducer
  :: Haskakafka.InternalSetup.ConfigOverrides
     -> Haskakafka.InternalSetup.ConfigOverrides
     -> [Char]
     -> IO ([Char], Chan B.ByteString)
startProducer kafkaConfig topicConfig topic = do
  putStrLn $ "Starting producer client for topic: " ++ topic
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
  run 8080 $ app jsonFromRequest channels topics

app
  :: Foldable t =>
     (Request -> B.ByteString)
     -> [(String, Chan B.ByteString)]
     -> t String
     -> Request
     -> (Response -> IO b)
     -> IO b
app payloadFromRequest producerChannels topics request respond
  | hasTopic = do
      _ <- writeChan channel payload
      respond $ messageProduced $ BL.fromStrict payload
  | otherwise  = respond notFound
  where hasTopic = pathRoot `elem` topics
        (Just channel) = lookup pathRoot producerChannels
        pathRoot = T.unpack $ head $ pathInfo request
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

notFound :: Response
notFound = responseLBS
  status404
  defaultHeader
  "404 - Not Found"
