{-# LANGUAGE OverloadedStrings #-}
import Control.Concurrent
import Control.Monad (forever)
import Control.Concurrent.Chan
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Haskakafka
import           Network.HTTP.Types
import           Network.HTTP.Types.Header ()
import           Network.Wai
import           Network.Wai.Handler.Warp (run)

main :: IO ()
main = do
  let
    kafkaConfig = [("socket.timeout.ms", "50000")]
    topicConfig = [("request.timeout.ms", "50000")]
  putStrLn "Server started on: http://localhost:8080/"
  producerChan <- newChan
  _ <- forkIO $ withKafkaProducer kafkaConfig topicConfig
    "broker2:9092" "sandbox"
    $ \_ topic ->  forever $ do
    payload <- readChan producerChan
    produceMessage topic KafkaUnassignedPartition
      $ KafkaProduceMessage payload
  run 8080 $ app jsonFromRequest producerChan

app
  :: (Request -> B.ByteString)
     -> Chan B.ByteString -> Request -> (Response -> IO b) -> IO b
app payloadFromRequest producerChan request respond
  | isTracking = do
      writeChan producerChan payload
      respond $ messageProduced $ BL.fromStrict payload
  | otherwise  = respond notFound
  where isTracking = pathRoot `elem` ["w", "k"]
        pathRoot = head $ pathInfo request
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
