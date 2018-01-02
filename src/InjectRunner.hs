{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2018  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
module InjectRunner
    ( InjectChan
    , makeInject
    , registerInjectHandler
    , injectEvt

    , Inject (..)
    )
where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, tryReadTChan, writeTChan)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr)
import System.Posix.Types (Fd)
import System.Posix.IO (createPipe, fdRead, fdWriteBuf)
import Graphics.Wayland.Server (displayGetEventLoop, eventLoopAddFd, clientStateReadable)

import Graphics.Wayland.WlRoots.Output (OutputMode, setOutputMode)

import Output (Output (outputRoots))
import Waymonad (getState, makeCallback2)
import Waymonad.Types (Way, WayBindingState (..), Compositor (..))

data Inject = ChangeMode Output (Ptr OutputMode)

data InjectChan = InjectChan
    { injectChan  :: TChan Inject
    , injectWrite :: Fd
    , injectRead  :: Fd
    }

handleInjected :: Inject -> Way a ()
handleInjected (ChangeMode out mode) =
    liftIO $ setOutputMode mode (outputRoots out)

readInjectEvt :: InjectChan -> Way a ()
readInjectEvt chan = do
    next <- liftIO . atomically . tryReadTChan $ injectChan chan
    case next of
        Just x -> do
            void . liftIO $ fdRead (injectRead chan) 1
            handleInjected x
            readInjectEvt chan
        Nothing -> pure ()

injectEvt :: Inject -> Way a ()
injectEvt inj = do
    chan <- wayInjectChan <$> getState
    liftIO . atomically $ writeTChan (injectChan chan) inj
    void . liftIO $ with 1 $ \ptr -> fdWriteBuf (injectWrite chan) ptr 1

registerInjectHandler :: Way a ()
registerInjectHandler = do
    display <- compDisplay . wayCompositor <$> getState
    chan <- wayInjectChan <$> getState
    evtLoop <- liftIO $ displayGetEventLoop display
    cb <- makeCallback2 $ \_ _ -> readInjectEvt chan >> pure False

    void . liftIO $ eventLoopAddFd
        evtLoop
        (injectRead chan)
        clientStateReadable
        cb

makeInject :: IO InjectChan
makeInject = do
    (readFd, writeFd) <- liftIO $ createPipe
    chan <- newTChanIO
    pure $ InjectChan chan writeFd readFd