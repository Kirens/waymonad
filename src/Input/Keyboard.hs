module Input.Keyboard
where

import Control.Monad.IO.Class (liftIO)
import Data.Word (Word32)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable(..))
import Graphics.Wayland.Server
    ( DisplayServer
    , displayTerminate
    )
import Graphics.Wayland.Signal
    ( addListener
    , WlListener (..)
    )
import Graphics.Wayland.WlRoots.Seat (WlrSeat, keyboardNotifyKey, keyboardNotifyModifiers, seatSetKeyboard)
import Graphics.Wayland.WlRoots.Backend.Multi (getSession')
import Graphics.Wayland.WlRoots.Backend.Session (changeVT)
import Graphics.Wayland.WlRoots.Backend (Backend)
import Graphics.Wayland.WlRoots.Input (InputDevice)
import Graphics.Wayland.WlRoots.Input.Keyboard
    ( WlrKeyboard
    , KeyboardSignals (..)
    , getKeySignals
    , getKeyDataPtr
    , EventKey (..)
    , KeyState (..)
    , setKeymap
    , getKeystate

    , KeyboardModifiers (..)
    , readModifiers

    , getModifiers
    )
import Foreign.StablePtr
    ( newStablePtr
    , castStablePtrToPtr
    , freeStablePtr
    , castPtrToStablePtr
    )
import Control.Monad (forM, when)

import ViewSet (WSTag)
import Waymonad
    ( BindingMap
    , withSeat
    , Way
    )
import WayUtil (setSignalHandler)

import Text.XkbCommon.Keymap
import Text.XkbCommon.Types
import Text.XkbCommon.Context
import Text.XkbCommon.KeyboardState
import Text.XkbCommon.KeycodeList
import Text.XkbCommon.KeysymPatterns

import qualified Data.Map as M

data Keyboard = Keyboard
    { keyboardDevice :: Ptr WlrKeyboard
    , keyboardIDevice :: Ptr InputDevice
    }

keyStateToDirection :: KeyState -> Direction
keyStateToDirection KeyReleased = keyUp
keyStateToDirection KeyPressed  = keyDown


switchVT :: Ptr Backend -> Word -> IO ()
switchVT backend vt = do
    mSession <- getSession' backend
    case mSession of
        Nothing -> pure ()
        Just s -> changeVT s vt


handleKeyPress
    :: WSTag a
    => DisplayServer
    -> Ptr Backend
    -> BindingMap a
    -> Word32
    -> Keysym
    -> Way a Bool
handleKeyPress dsp backend bindings modifiers sym@(Keysym key) =
    case sym of
        Keysym_Escape -> liftIO (displayTerminate dsp) >> pure True
        -- Would be cooler if this wasn't a listing of VTs (probably TH)
        Keysym_XF86Switch_VT_1  -> liftIO (switchVT backend 1 ) >> pure True
        Keysym_XF86Switch_VT_2  -> liftIO (switchVT backend 2 ) >> pure True
        Keysym_XF86Switch_VT_3  -> liftIO (switchVT backend 3 ) >> pure True
        Keysym_XF86Switch_VT_4  -> liftIO (switchVT backend 4 ) >> pure True
        Keysym_XF86Switch_VT_5  -> liftIO (switchVT backend 5 ) >> pure True
        Keysym_XF86Switch_VT_6  -> liftIO (switchVT backend 6 ) >> pure True
        Keysym_XF86Switch_VT_7  -> liftIO (switchVT backend 7 ) >> pure True
        Keysym_XF86Switch_VT_8  -> liftIO (switchVT backend 8 ) >> pure True
        Keysym_XF86Switch_VT_9  -> liftIO (switchVT backend 9 ) >> pure True
        Keysym_XF86Switch_VT_10 -> liftIO (switchVT backend 10) >> pure True
        Keysym_XF86Switch_VT_11 -> liftIO (switchVT backend 11) >> pure True
        Keysym_XF86Switch_VT_12 -> liftIO (switchVT backend 12) >> pure True
        _ -> case M.lookup (modifiers, key) bindings of
                Nothing -> pure False
                Just fun -> fun >> pure True


tellClient :: Ptr WlrSeat -> Keyboard -> EventKey -> IO ()
tellClient seat keyboard event = do
    seatSetKeyboard seat $ keyboardIDevice keyboard
    keyboardNotifyKey seat (timeSec event) (keyCode event) (state event)

handleKeyEvent
    :: WSTag a
    => DisplayServer
    -> Ptr Backend
    -> Keyboard
    -> Ptr WlrSeat
    -> BindingMap a
    -> Ptr EventKey
    -> Way a ()
handleKeyEvent dsp backend keyboard seat bindings ptr = withSeat (Just seat) $ do
    event <- liftIO $ peek ptr
    let keycode = fromEvdev . fromIntegral . keyCode $ event
    keyState <- liftIO $ getKeystate $ keyboardDevice keyboard
    syms <- liftIO $ getStateSymsI keyState keycode
    modifiers <- liftIO $ getModifiers $ keyboardDevice keyboard
    handled <- forM syms $ \sym -> case (state event) of
        -- We currently don't do anything special for releases
        KeyReleased -> pure False
        KeyPressed ->
            handleKeyPress dsp backend bindings modifiers sym

    liftIO $
        when (not $ foldr (||) False handled) $
            tellClient seat keyboard event

handleModifiers :: Keyboard -> Ptr WlrSeat -> Ptr a -> IO ()
handleModifiers keyboard seat _ = do
    mods <- readModifiers $ keyboardDevice keyboard
    seatSetKeyboard seat $ keyboardIDevice keyboard
    keyboardNotifyModifiers seat (modDepressed mods) (modLatched mods) (modLocked mods) (modGroup mods)

handleKeyboardAdd
    :: WSTag a
    => DisplayServer
    -> Ptr Backend
    -> Ptr WlrSeat
    -> BindingMap a
    -> Ptr InputDevice
    -> Ptr WlrKeyboard
    -> Way a ()
handleKeyboardAdd dsp backend seat bindings dev ptr = do
    let signals = getKeySignals ptr

    liftIO $ do
        (Just cxt) <- newContext defaultFlags
        (Just keymap) <- newKeymapFromNamesI cxt noPrefs
        setKeymap ptr keymap

    let keyboard = Keyboard ptr dev

    kh <- setSignalHandler
        (keySignalKey signals)
        (handleKeyEvent dsp backend keyboard seat bindings)
    mh <- liftIO $ addListener (WlListener $ handleModifiers keyboard seat) (keySignalModifiers signals)

    liftIO $ do
        sptr <- newStablePtr (kh, mh)
        poke (getKeyDataPtr ptr) (castStablePtrToPtr sptr)


handleKeyboardRemove :: Ptr WlrKeyboard -> IO ()
handleKeyboardRemove ptr = do
    sptr <- peek (getKeyDataPtr ptr)
    freeStablePtr $ castPtrToStablePtr sptr
