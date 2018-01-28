{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

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
module WayUtil.Floating
    ( centerFloat
    , toggleFloat
    , isFloating
    , getFloats
    , modifyFloating
    , unsetFloating
    , setFloating
    )
where

import Control.Monad (when, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef, readIORef)
import Data.Set (Set)

import Graphics.Wayland.WlRoots.Box (WlrBox (..))

import Input.Seat (Seat, keyboardEnter)
import Utility (doJust)
import View (View, moveView, resizeView, setViewFocus, unsetViewFocus)
import ViewSet (WSTag, FocusCore (..))
import Waymonad
    ( Way
    , WayBindingState (..)
    , getState
    , makeCallback2
    , getSeat
    )
import WayUtil.Current (getCurrentBox, getCurrentView, getCurrentWS)
import WayUtil.ViewSet (modifyFocusedWS, insertView)

import qualified Data.Set as S

modifyFloating :: (Set View -> Set View) -> Way vs a ()
modifyFloating fun = liftIO . flip modifyIORef fun . wayFloating =<< getState

getFloats :: Way vs a (Set View)
getFloats = liftIO . readIORef . wayFloating =<< getState

isFloating :: View -> Way vs a Bool
isFloating v = S.member v <$> getFloats


focusFloating :: Seat -> View -> Way vs ws ()
focusFloating seat view = void $ keyboardEnter seat view

setFloating :: View -> WlrBox -> Way vs a ()
setFloating view (WlrBox x y width height) = do
    moveView view (fromIntegral x) (fromIntegral y)
    resizeView view (fromIntegral width) (fromIntegral height)
    setViewFocus view =<< makeCallback2 focusFloating
    modifyFloating $ S.insert view

unsetFloating :: (WSTag a, FocusCore vs a) => View -> Way vs a ()
unsetFloating view = do
    floats <- isFloating view
    when floats $ do
        unsetViewFocus view
        modifyFloating $ S.delete view
        ws <- getCurrentWS
        seat <- getSeat
        insertView view ws seat

toggleFloat :: (WSTag a, FocusCore vs a) => WlrBox ->  Way vs a ()
toggleFloat box = doJust getCurrentView $ \view -> do
    floats <- isFloating view
    if floats
        then unsetFloating view
        else do
            modifyFocusedWS (\_ ws vs -> _removeView ws view vs)
            setFloating view box


centerFloat :: (WSTag a, FocusCore vs a) => Way vs a ()
centerFloat = doJust getCurrentBox $ \(WlrBox x y w h) -> do
    let nw = w `div` 2
    let nh = h `div` 2
    toggleFloat $ WlrBox (x + nw `div` 2) (y + nh `div` 2) nw nh
