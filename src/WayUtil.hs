{-# LANGUAGE FlexibleContexts #-}
module WayUtil
where

import Control.Monad (when, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IORef (readIORef, modifyIORef, writeIORef)
import Data.Maybe (fromJust)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Tuple (swap)
import Foreign.Ptr (Ptr)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Process (spawnCommand)

import Graphics.Wayland.Signal
    ( addListener
    , WlListener (..)
    , ListenerToken
    , WlSignal
    )
import Graphics.Wayland.WlRoots.Seat (WlrSeat, keyboardNotifyEnter)

import Layout (reLayout)
import Utility (whenJust)
import View (View, getViewSurface, activateView)
import ViewSet
    ( Workspace (..)
    , Zipper (..)
    , WSTag
    , SomeMessage (..)
    , Message
    , ViewSet
    , getFocused
    , getMaster
    , setFocused
    , messageWS
    )
import Waymonad
    ( WayBindingState(..)
    , Way
    , getState
    , getSeat
    , setCallback
    )

import qualified Data.Map as M

getCurrent :: (WSTag a) => Way a Int
getCurrent = do
    state <- getState
    (Just seat) <- getSeat
    currents <- liftIO . readIORef $ wayBindingCurrent state
    let (Just current) = M.lookup seat $ M.fromList currents
    pure current

modifyCurrentWS
    :: (WSTag a)
    => (Ptr WlrSeat -> Workspace -> Workspace) -> Way a ()
modifyCurrentWS fun = do
    state <- getState
    (Just seat) <- getSeat
    mapping <- liftIO . readIORef $ wayBindingMapping state
    current <- getCurrent
    case M.lookup current . M.fromList $ map swap mapping of
        Nothing -> pure ()
        Just ws -> do
            logPutStr $ "Changing contents of workspace: " ++ show ws
            preWs <- getFocused seat . fromJust . M.lookup ws <$> getViewSet
            modifyViewSet (M.adjust (fun seat) ws)
            postWs <- getFocused seat . fromJust . M.lookup ws <$> getViewSet
            reLayout ws

            liftIO $ when (preWs /= postWs) $ whenJust postWs $ \v ->
                keyboardNotifyEnter seat =<< getViewSurface v

    runLog

setWorkspace :: WSTag a => a -> Way a ()
setWorkspace ws = do
    state <- getState
    current <- getCurrent
    liftIO $ modifyIORef
        (wayBindingMapping state)
        ((:) (ws, current) . filter ((/=) current . snd))

    reLayout ws
    focusMaster

focusMaster :: WSTag a => Way a ()
focusMaster = do
    state <- getState
    (Just seat) <- getSeat
    mapping <- liftIO . readIORef $ wayBindingMapping state
    current <- getCurrent
    wss <- liftIO . readIORef $ wayBindingState state
    let ws = M.lookup current . M.fromList $ map swap mapping
    whenJust (getMaster =<< flip M.lookup wss =<< ws) $ \view -> do
        modifyCurrentWS (setFocused view)
        liftIO $ do
            activateView view True
            surf <- getViewSurface view
            keyboardNotifyEnter seat surf


spawn :: (MonadIO m) => String -> m ()
spawn = void . liftIO . spawnCommand

setFocus :: MonadIO m => (Maybe (Ptr WlrSeat), View) -> m ()
setFocus (Nothing, _) = pure ()
setFocus (Just s, v) = liftIO $ do
    activateView v True
    surf <- getViewSurface v
    keyboardNotifyEnter s surf

setFoci :: MonadIO m => Workspace -> m ()
setFoci (Workspace _ Nothing) = pure ()
setFoci (Workspace _ (Just (Zipper xs))) = mapM_ setFocus xs

sendMessage :: (WSTag a, Message t) => t -> Way a ()
sendMessage m = modifyCurrentWS $ \_ -> messageWS (SomeMessage m)

runLog :: (WSTag a) => Way a ()
runLog = do
    state <- getState
    wayLogFunction state

setSignalHandler
    :: Ptr (WlSignal a)
    -> (Ptr a -> Way b ())
    -> Way b ListenerToken
setSignalHandler signal act = 
    setCallback act (\fun -> addListener (WlListener fun) signal)


setSeatOutput :: Ptr WlrSeat -> Int -> Way a ()
setSeatOutput seat out = do
    state <- getState
    -- TODO: Make sure this works with multiseat
    liftIO $ writeIORef (wayBindingCurrent state) [(seat, out)]


modifyViewSet :: (ViewSet a -> ViewSet a) -> Way a ()
modifyViewSet fun = do
    ref <- wayBindingState <$> getState
    liftIO $ modifyIORef ref fun

getViewSet :: Way a (ViewSet a)
getViewSet = liftIO . readIORef . wayBindingState =<< getState

logPutTime :: IO ()
logPutTime = do
    time <- getCurrentTime
    let formatted = formatTime defaultTimeLocale "%0Y-%m-%d %H:%M:%S - " time

    hPutStr stderr formatted

logPutStr :: MonadIO m => String -> m ()
logPutStr arg = liftIO $ do
    logPutTime
    hPutStrLn stderr arg

logPrint :: (Show a, MonadIO m) => a -> m ()
logPrint = logPutStr . show

