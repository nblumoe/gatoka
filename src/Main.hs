{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Haskakafka
import           Network.HTTP.Types
import           Network.HTTP.Types.Header
import           Network.Wai
import           Network.Wai.Handler.Warp (run)

app:: KafkaTopic -> Application
app topic request respond
  | isTracking = do
      _ <- forkIO $ produceTrackingMessage topic payload
      respond $ tracking $ BL.fromStrict payload
  | otherwise  = respond notFound
  where isTracking = pathRoot `elem` ["w", "k"]
        pathRoot = head $ pathInfo request
        payload = payloadFromRequest request

produceTrackingMessage :: KafkaTopic -> B.ByteString -> IO ()
produceTrackingMessage topic payload = do
  let message = KafkaProduceMessage payload
  _ <- produceMessage topic KafkaUnassignedPartition message
  return ()

main :: IO ()
main = do
  let
    kafkaConfig = [("socket.timeout.ms", "50000")]
    topicConfig = [("request.timeout.ms", "50000")]
  putStrLn "Server started on: http://localhost:8080/"
  withKafkaProducer kafkaConfig topicConfig
    "broker2:9092" "sandbox"
    $ \_ topic -> run 8080 $ app topic

defaultHeader :: [(HeaderName, B.ByteString)]
defaultHeader = [(hContentType, "text/plain")]

formatQueryItem :: QueryItem -> B.ByteString
formatQueryItem ("", _) = ""
formatQueryItem (k, Just "") = B.append k ": undefined"
formatQueryItem (k, Nothing) = B.append k ": undefined"
formatQueryItem (k, Just v) = B.concat [k, ": ",  v]

payloadFromRequest :: Request -> B.ByteString
payloadFromRequest request = B.concat ["{", query_items, "}"]
  where query_items = B.intercalate ", " $ map formatQueryItem $ queryString request

tracking :: BL.ByteString -> Response
tracking = responseLBS
  status200
  defaultHeader

notFound :: Response
notFound = responseLBS
  status404
  defaultHeader
  "404 - Not Found"
