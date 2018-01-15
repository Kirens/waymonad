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
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Fuse.Outputs
    ( outputsDir
    )
where

import Control.Monad.IO.Class (liftIO)
import Data.Map (Map)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Foreign.C.Error (Errno, eINVAL, eBADF)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (peek))
import Formatting (sformat, (%), int, float)

import Graphics.Wayland.Server
    ( OutputTransform
    , outputTransformNormal
    , outputTransform180
    , outputTransform90
    , outputTransform270
    , outputTransformFlipped
    , outputTransformFlipped_180
    , outputTransformFlipped_90
    , outputTransformFlipped_270
    )

import Graphics.Wayland.WlRoots.Box (WlrBox (..), Point (..))
import Graphics.Wayland.WlRoots.Output
    ( getMode
    , getModes
    , getWidth
    , getHeight
    , hasModes
    , OutputMode (..)
    , getOutputTransform
    -- TODO: This should probably be done in the main loop
    , transformOutput
    , getOutputScale
    , getOutputBox
    , outputEnable
    , outputDisable

    , getMake
    , getModel
    , getSerial
    , effectiveResolution
    , setOutputMode
    , setOutputScale
    )
import Graphics.Wayland.WlRoots.OutputLayout (moveOutput)

import Output (Output(..), findMode, outputFromWlr)
import ViewSet (WSTag (..))
import Waymonad (getState)
import Waymonad.Types (Way, WayBindingState (..), Compositor (..))
import WayUtil (getOutputs)
import WayUtil.Focus (getOutputWorkspace)

import Fuse.Common

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Read as R (rational, decimal)

parsePosition :: Text -> Either String (Point, Text)
parsePosition txt = do
    (x, nxt1) <- R.decimal txt
    (c, nxt2) <- maybe (Left "Only got one coordinate") Right $ T.uncons nxt1
    if c /= 'x'
        then Left "Seperator has to be 'x'"
        else Right ()
    (y, ret) <- R.decimal nxt2
    pure (Point x y, ret)

readMode :: Output -> Text -> IO (Maybe (Ptr OutputMode))
readMode out txt = do
    let parsed = do
            (Point width height, nxt) <- parsePosition txt
            refresh <- case T.uncons nxt of
                            Nothing -> Right Nothing
                            Just (at, ref) -> do
                                if at == '@'
                                    then Right ()
                                    else Left "Rate seperator has to be '@'"
                                pure $ fst <$> either (const Nothing) Just (R.decimal ref)
            -- wlroots expects milli hertz, so if someone just inputs @60,
            -- multiply by 1000, to get a fitting value
            let adjust val = if val < 1000 then val * 1000 else val
            pure (width, height, adjust <$> refresh)
    case parsed of
        Left _ -> pure Nothing
        Right (width, height, ref) -> findMode
                (outputRoots out)
                (fromIntegral width)
                (fromIntegral height)
                ref

formatMode :: OutputMode -> Text
formatMode mode = sformat
    (int % "x" % int % "@" % int)
    (modeWidth mode)
    (modeHeight mode)
    (modeRefresh mode)

makeModesText :: Output -> Way vs a Text
makeModesText out = do
    modes <- liftIO (mapM peek =<< getModes (outputRoots out))
    pure $ T.intercalate "\n" $ fmap formatMode modes

readTransform :: Text -> Maybe OutputTransform
readTransform "Normal" = Just outputTransformNormal
readTransform "90" = Just outputTransform90
readTransform "180" = Just outputTransform180
readTransform "270" = Just outputTransform270
readTransform "Flipped" = Just outputTransformFlipped
readTransform "Flipped90" = Just outputTransformFlipped_90
readTransform "Flipped180" = Just outputTransformFlipped_180
readTransform "Flipped270" = Just outputTransformFlipped_270
readTransform _ = Nothing

-- By going through this, we get the same output again, but we ensure that it's
-- still valid.
ensureOutput :: Output -> (Way vs ws Text) -> Way vs ws Text
ensureOutput out fun = do
    roots <- outputFromWlr $ outputRoots out
    maybe (pure "Output was disconnected since this file was opened") (const fun) roots

ensureWOutput :: Output -> Way vs ws (Either Errno a) -> Way vs ws (Either Errno a)
ensureWOutput out fun = do
    roots <- outputFromWlr $ outputRoots out
    maybe (pure $ Left eBADF) (const fun) roots


makeOutputDir :: WSTag a => Output -> Way vs a (Entry vs a)
makeOutputDir out = do
    let guaranteed =
            [ ("width",  FileEntry $ textFile $ ensureOutput out $ liftIO (sformat int <$> getWidth  (outputRoots out)))
            , ("height", FileEntry $ textFile $ ensureOutput out $ liftIO (sformat int <$> getHeight (outputRoots out)))
            , ("effective", FileEntry $ textFile $ ensureOutput out $ liftIO (uncurry (sformat (int % "x" % int)) <$> effectiveResolution (outputRoots out)))
            ]

    let handleMaybe :: Monad m => (m a -> b) -> m (Maybe a) -> m (Maybe b)
        handleMaybe fun gen = do
            val <- gen
            case val of
                Nothing -> pure Nothing
                Just x -> pure $ Just $ fun $ pure x
    info <- liftIO $ sequence
            [ handleMaybe (("make", ) . FileEntry . textFile . ensureOutput out . liftIO) $ getMake (outputRoots out)
            , handleMaybe (("model", ) . FileEntry . textFile . ensureOutput out . liftIO) $ getModel (outputRoots out)
            , handleMaybe (("serial", ) . FileEntry . textFile . ensureOutput out . liftIO) $ getSerial (outputRoots out)
            ]

    hm <- liftIO $ hasModes $ outputRoots out
    let modes = if hm
            then
                [ ("modes", FileEntry $ textFile . ensureOutput out $ makeModesText out)
                , ("mode", FileEntry $ textRWFile
                    (ensureOutput out . liftIO $ maybe (pure "None") (fmap formatMode . peek) =<< getMode (outputRoots out))
                    (\txt -> ensureWOutput out . liftIO $ do
                        mode <- readMode out txt
                        case mode of
                            Just x -> Right <$> setOutputMode x (outputRoots out)
                            Nothing -> pure $ Left eINVAL
                    )
                  )
                ]
            else []

    ws <- getOutputWorkspace out
    let wsLink = case ws of
            Nothing -> []
            Just xs -> [("ws", SymlinkEntry (pure $ "../../workspaces/" ++ T.unpack (getName xs)))]

    let transform = ("transform", FileEntry $ textRWFile
            (ensureOutput out $ liftIO (T.pack . show <$> getOutputTransform (outputRoots out)))
            (\txt -> ensureWOutput out $ case readTransform txt of
                        Nothing -> pure $ Left eINVAL
                        Just trans -> liftIO $ Right <$> transformOutput (outputRoots out) trans
            )
                    )

    let scale = ("scale", FileEntry $ textRWFile
            (ensureOutput out $ liftIO (sformat float <$> getOutputScale (outputRoots out)))
            (\txt -> ensureWOutput out . liftIO $ case R.rational txt of
                        Left _ -> pure $ Left eINVAL
                        Right (x, _) -> Right <$> setOutputScale (outputRoots out) x
            )
                )

    let position = ("position", FileEntry $ textRWFile
            (ensureOutput out . liftIO $ do
                box <- getOutputBox (outputRoots out)
                pure $ sformat (int % "x" % int) (boxX box) (boxY box)
            )
            (\txt -> ensureWOutput out $ case parsePosition txt of
                        Left _ -> pure $ Left eINVAL
                        Right (Point x y, _) -> Right <$> do
                            layout <- compLayout . wayCompositor <$> getState
                            liftIO $ moveOutput layout (outputRoots out) x y
            )
                   )

    let dpms = ("dpms", FileEntry $ textRWFile
            (pure "Can't read enabled state yet"
            )
            (\txt -> ensureWOutput out $ liftIO $ case txt of
                        "enable"  -> Right <$> outputEnable (outputRoots out)
                        "disable" -> Right <$> outputDisable (outputRoots out)
                        _ ->  pure $ Left eINVAL
            )
                   )

    pure $ DirEntry $ simpleDir $ M.fromList $
        dpms: position: scale: transform:
        guaranteed ++ modes ++ wsLink ++ catMaybes info

enumerateOuts :: WSTag a => Way vs a (Map String (Entry vs a))
enumerateOuts = do
    outputs <- getOutputs
    M.fromList <$> mapM (\out -> (T.unpack $ outputName out, ) <$> makeOutputDir out) outputs

outputsDir :: WSTag a => Entry vs a
outputsDir = DirEntry $ enumeratingDir enumerateOuts
