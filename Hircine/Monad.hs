{-# LANGUAGE RankNTypes #-}

module Hircine.Monad (

    -- * Types
    Hircine,

    -- * Operations
    receive,
    send,
    buffer,
    fork,

    -- * Running the bot
    runHircine

    ) where


import Control.Monad
import Control.Monad.Trans.Reader
import Data.IORef
import qualified SlaveThread

import Hircine.Core
import Hircine.Command
import Hircine.Stream


type Hircine = ReaderT Stream IO


-- | Receive a single IRC message from the server.
receive :: Hircine Message
receive = ReaderT streamReceive

-- | Send an IRC command to the server.
send :: IsCommand c => c -> Hircine ()
send c = ReaderT $ \s -> streamSend s [toCommand c]

-- | Buffer up the inner 'send' calls, so that all the commands are sent
-- in one go.
buffer :: Hircine a -> Hircine a
buffer h = ReaderT $ \s -> do
    buf <- newIORef []
    r <- runReaderT h s {
        streamSend = \cs ->
            atomicModifyIORef' buf $ \css ->
                css `seq` (cs : css, ())
        }
    -- Poison the IORef, so that no-one can touch it any more
    css <- atomicModifyIORef buf $ \css -> (error "messages already sent", css)
    let cs = concat $ reverse css
    -- Perform the reversal *before* calling hsSend
    -- This minimizes the time spent in hsSend's critical section
    cs `seq` streamSend s cs
    return r


-- | Run the inner action in a separate thread.
--
-- See the "SlaveThread" documentation for tips and caveats.
fork :: Hircine () -> Hircine ()
fork h = ReaderT $ void . SlaveThread.fork . runReaderT h


runHircine :: Hircine a -> Stream -> IO a
runHircine = runReaderT
