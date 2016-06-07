{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Network.Wai
import Network.HTTP.Types
import Network.HTTP.Types.Header
import Network.Wai.Handler.Warp (run)

app :: Request -> (Response -> t) -> t
app request respond
  | isTracking = respond $ tracking request
  | otherwise  = respond notFound
  where isTracking = elem pathRoot ["w", "k"]
        pathRoot = (head $ pathInfo request)

main :: IO ()
main = do
  putStrLn "Server started on: http://localhost:8080/"
  run 8080 app

defaultHeader = [(hContentType, "text/plain")]

formatQueryItem :: QueryItem -> B.ByteString
formatQueryItem (k, Just v) = B.concat [k, ": ",  v, "\n"]
formatQueryItem (k, Nothing) = k

tracking :: Request -> Response
tracking request = responseLBS
  status200
  defaultHeader
  $ BL.fromStrict $ B.concat $ map formatQueryItem $ queryString request

notFound :: Response
notFound = responseLBS
  status404
  defaultHeader
  "404 - Not Found"
