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
module Input.Seat
    ( Seat (seatRoots, seatName, seatLoadScale)
    , getPointerFocus
    , getKeyboardFocus
    )
where

import Control.Monad.IO.Class (MonadIO)
import Data.IORef (IORef)
import Foreign.Ptr (Ptr)

import View (View)

import qualified Graphics.Wayland.WlRoots.Seat as R

data Seat = Seat
    { seatRoots          :: Ptr R.WlrSeat
    , seatPointer        :: IORef (Maybe View)
    , seatKeyboard       :: IORef (Maybe View)
    , seatName           :: String
    , seatRequestDefault :: IO ()
    , seatLoadScale      :: Float -> IO ()
    }

instance Show Seat
instance Eq Seat
instance Ord Seat

getPointerFocus :: MonadIO m => Seat -> m (Maybe View)
getKeyboardFocus :: MonadIO m => Seat -> m (Maybe View)