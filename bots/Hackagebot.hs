{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import Data.Default.Class
import Data.Foldable
import Data.Function
import Data.List
import Data.Monoid
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.Connection
import Network.HTTP.Client
import System.Clock
import System.Timeout
import Text.Feed.Import
import Text.Feed.Query

import Hircine

import Utils


main :: IO ()
main = do
    crateMap <- newIORef defaultCrateMap
    channelIdle <- newIORef =<< getMonotonicTime
    newCrates <- newChan
    cratesToSend <- newIORef []
    startBot params $ \channel man -> do
        fork . liftIO $ checkNewCrates crateMap newCrates man
        fork $ notifyNewCrates newCrates cratesToSend channelIdle channel
        return $ do
            accept $ \(PrivMsg targets _) ->
                when (channel `elem` targets) $ liftIO $ do
                    currentTime <- getMonotonicTime
                    atomicWriteIORef channelIdle $! currentTime + channelIdleDelay
  where
    params = ConnectionParams
        { connectionHostname = "chat.freenode.net"
        , connectionPort = 6697
        , connectionUseSecure = Just def
        , connectionUseSocks = Nothing
        }


checkNewCrates :: IORef CrateMap -> Chan Crate -> Manager -> IO a
checkNewCrates crateMap newCrates man = forever $ do
    changedCrates <- fetchAndUpdateCrateMap feedUrl parseCrates crateMap man
    writeList2Chan newCrates changedCrates
    threadDelay $ 60 * 1000 * 1000  -- 60 seconds
  where
    feedUrl = "https://hackage.haskell.org/packages/recent.rss"

    parseCrates = parseFeedSource >=> parseFeed
    parseFeed = traverse parseItem . getFeedItems
    parseItem item = do
        (name, version) <- parseTitle =<< getItemTitle item
        (_, description) <- Text.breakOnEnd "<p>" <$> getItemDescription item
        return $ Crate name version description
    parseTitle title
        | [name, version] <- Text.words title = Just (name, version)
        | otherwise = Nothing


notifyNewCrates :: Chan Crate -> IORef [Crate] -> IORef TimeSpec -> ByteString -> Hircine ()
notifyNewCrates newCrates cratesToSend channelIdle channel = start
  where
    start = do
        leftovers <- liftIO $ readIORef cratesToSend
        when (null leftovers) $ do
            firstCrate <- liftIO $ readChan newCrates
            liftIO $ writeIORef cratesToSend $! [firstCrate]
        startTime <- liftIO getMonotonicTime
        loop startTime (startTime + notifyDelay)

    loop currentTime notifyTime = do
        channelIdleTime <- liftIO $ readIORef channelIdle
        let timeToWait = toMicroSecs $ max notifyTime channelIdleTime - currentTime
        if timeToWait > 0
            then do
                _ <- liftIO $ timeout timeToWait $ forever $ do
                    crate <- readChan newCrates
                    -- IORef operations are not interruptible, so there is no
                    -- threat of data loss here
                    modifyIORef' cratesToSend (crate :)  -- :)
                currentTime' <- liftIO getMonotonicTime
                loop currentTime' notifyTime
            else do
                messages <- liftIO $ summarizeCrates <$> readIORef cratesToSend
                buffer . for_ messages $
                    send . PrivMsg [channel] . Text.encodeUtf8 . meify
                liftIO $ writeIORef cratesToSend $! []
                start


summarizeCrates :: [Crate] -> [Text]
summarizeCrates crates
    | length crates < 3 = showIndividually crates  -- <3
    | otherwise = showCompactly crates
  where
    showIndividually = map (showCrate baseUrl)
    baseUrl = "https://hackage.haskell.org/package/"

    showCompactly = showCompactly' . splitAt 4 . shuffleCrates
    showCompactly' (former, latter) = [firstLine, secondLine]
      where
        firstLine = Text.intercalate ", " $
            map showCrateNameVersion former ++ andMore
        andMore
            | null latter = []
            | otherwise = ["… and " <> Text.pack (show (length latter)) <> " more"]
        secondLine = " → https://hackage.haskell.org/packages/recent"


shuffleCrates :: [Crate] -> [Crate]
shuffleCrates = disperseSimilarCrates . sortAndRemoveDuplicates
  where
    -- | Shuffle the list of packages such that those with similar names are
    -- spaced farther apart.
    --
    -- This avoids the \"amazonka problem\", where a flurry of published
    -- packages from a single framework ends up crowding out independent ones.
    --
    -- Note that because of the call to 'groupBy', this function expects its
    -- input to be sorted by package name.
    disperseSimilarCrates :: [Crate] -> [Crate]
    disperseSimilarCrates = concat . transpose . groupBy ((==) `on` crateFamily)

    -- | Sort a list of packages by name, and remove duplicate packages with the
    -- same name.
    sortAndRemoveDuplicates :: [Crate] -> [Crate]
    sortAndRemoveDuplicates = map head . groupBy ((==) `on` crateName) . sortOn crateName

    crateFamily :: Crate -> Text
    crateFamily = Text.takeWhile (/= '-') . crateName


channelIdleDelay :: TimeSpec
channelIdleDelay = TimeSpec { sec = 60, nsec = 0 }

notifyDelay :: TimeSpec
notifyDelay = TimeSpec { sec = 5 * 60, nsec = 0 }


meify :: Text -> Text
meify text = "\x01\&ACTION " <> text <> "\x01"
