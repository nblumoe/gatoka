{-# LANGUAGE OverloadedStrings #-}
import Network.Wai
import Network.HTTP.Types
import Network.HTTP.Types.Header
import Network.Wai.Handler.Warp (run)

app :: Request -> (Response -> t) -> t
app request respond
  | isTracking = respond tracking
  | otherwise  = respond notFound
  where isTracking = elem pathRoot ["w", "k"]
        pathRoot = (head $ pathInfo request)

main :: IO ()
main = do
  putStrLn "Server started on: http://localhost:8080/"
  run 8080 app

defaultHeader
  :: [(HeaderName, Data.ByteString.Internal.ByteString)]
defaultHeader = [(hContentType, "text/plain")]

tracking :: Response
tracking = responseLBS
  status200
  defaultHeader
  "200 - Tracking call received"

notFound :: Response
notFound = responseLBS
  status404
  defaultHeader
  "404 - Not Found"
