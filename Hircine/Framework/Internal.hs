module Hircine.Framework.Internal (
    Handler(..),
    Action(..),
    SendFn,
    makeHandler,
    makeHandler',
    reifyHandler,
    contramapIO,
    mapOutput,
    mapOutputIO
    ) where


import Control.Applicative
import Control.Monad
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Monoid

import Hircine.Core


-- | A @'Handler' a@ accepts inputs of type @a@ and performs 'IO' in
-- response.
newtype Handler a = Handler {
    unHandler :: SendFn -> IO (Op (Action IO) a)
    }

-- | Use 'contramap' to transform incoming messages.
instance Contravariant Handler where
    contramap f (Handler h) = Handler $ fmap (fmap (contramap f)) h

-- | Use 'divide' to run two handlers on the same message.
instance Divisible Handler where
    divide f (Handler g) (Handler h) = Handler $ liftA2 (liftA2 (divide f)) g h
    conquer = Handler $ pure $ pure $ conquer

-- | Use 'choose' to switch dynamically between two handlers.
instance Decidable Handler where
    lose f = Handler $ pure $ pure $ lose f
    choose f (Handler g) (Handler h) = Handler $ liftA2 (liftA2 (choose f)) g h

instance Monoid (Handler a) where
    mempty = conquer
    mappend = divide (\a -> (a, a))

-- | A callback for sending 'Command's back to the server.
type SendFn = [Command] -> IO ()


makeHandler :: (SendFn -> IO (a -> IO ())) -> Handler a
makeHandler h = Handler $ fmap (Op . (Action .)) . h

makeHandler' :: (SendFn -> a -> IO ()) -> Handler a
makeHandler' h = makeHandler $ \send -> return $ \message -> h send message

reifyHandler :: Handler a -> SendFn -> IO (a -> IO ())
reifyHandler (Handler h) = fmap ((runAction .) . getOp) . h


-- | Like 'contramap', but allow performing 'IO' as well.
contramapIO :: (a -> IO b) -> Handler b -> Handler a
contramapIO f = makeHandler . (fmap (f >=>) .) . reifyHandler

-- | Apply a function to every outgoing message.
mapOutput :: ([Command] -> [Command]) -> Handler a -> Handler a
mapOutput f (Handler h) = Handler $ h . (. f)

-- | Like 'mapOutput', but allow performing 'IO' as well.
mapOutputIO :: ([Command] -> IO [Command]) -> Handler a -> Handler a
mapOutputIO f (Handler h) = Handler $ h . (f >=>)


newtype Action f = Action { runAction :: f () }

instance Applicative f => Monoid (Action f) where
    mempty = Action $ pure ()
    mappend (Action a) (Action b) = Action $ a *> b
