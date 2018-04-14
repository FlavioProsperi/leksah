{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fwarn-unused-imports #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Info
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
-- | The info Pane to show symbol information
--
-------------------------------------------------------------------------------

module IDE.Pane.Info (
    IDEInfo
,   InfoState(..)
,   showInfo
,   setInfo
,   setInfoStyle
,   replayInfoHistory
,   openDocu
) where

import Data.IORef
import Data.Typeable
import Data.Char (isAlphaNum)
import Network.URI (escapeURIString)

import IDE.Core.State
import IDE.SymbolNavigation
import IDE.Pane.SourceBuffer
import IDE.TextEditor (newDefaultBuffer, TextEditor(..), EditorView(..))
import IDE.Utils.GUIUtils (openBrowser, __)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad (unless, void)
import Data.Foldable (forM_)
import qualified Data.Text as T (unpack, pack, null)
import Data.Monoid ((<>))
import GI.Gtk.Objects.ScrolledWindow
       (scrolledWindowSetPolicy, ScrolledWindow(..))
import GI.Gtk.Objects.Widget (widgetHide, widgetShowAll, toWidget)
import GI.Gtk.Enums (PolicyType(..))
import GI.Gtk.Objects.Menu (Menu(..))
import GI.Gtk.Objects.Container (containerGetChildren)
import GI.Gtk.Objects.MenuItem
       (onMenuItemActivate, menuItemNewWithLabel)
import GI.Gtk.Objects.MenuShell (menuShellAppend)
import GI.Gtk.Objects.TextView (textViewSetEditable)
import IDE.SourceCandy (getCandylessPart)
import Graphics.UI.Frame.Rectangle (getRectangleY, getRectangleX)
import GI.Gdk (windowGetOrigin)
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)


-- | Represents the Info pane
data IDEInfo        =   forall editor. TextEditor editor => IDEInfo {
    sw              ::   ScrolledWindow
,   currentDescr    ::   IORef (Maybe Descr)
,   descriptionView ::   EditorView editor
} deriving Typeable


-- | The additional state used when recovering the pane
data InfoState              =   InfoState (Maybe Descr)
    deriving(Eq,Ord,Read,Show,Typeable,Generic)

instance ToJSON InfoState
instance FromJSON InfoState

instance Pane IDEInfo IDEM
    where
    primPaneName _  =   __ "Symbol Info"
    getAddedIndex _ =   0
    getTopWidget    =   liftIO . toWidget . sw
    paneId b        =   "*Info"


instance RecoverablePane IDEInfo InfoState IDEM where
    saveState p     =   do
        currentDescr' <-  liftIO $ readIORef (currentDescr p)
        return (Just (InfoState currentDescr'))
    recoverState pp (InfoState descr) =   do
        nb <- getNotebook pp
        buildPane pp nb builder
    builder pp nb windows =
        let idDescr = Nothing in do
        prefs <- readIDE prefs
        ideR <- ask
        descriptionBuffer <- newDefaultBuffer Nothing ""
        (descriptionView, sw) <- newView descriptionBuffer (textviewFont prefs)
        updateStyle descriptionBuffer
        setEditable descriptionView False
        setShowLineMarks descriptionView False
        setHighlightCurrentLine descriptionView False

        createHyperLinkSupport descriptionView sw (\_ _ iter -> do
                (beg, en) <- getIdentifierUnderCursorFromIter (iter, iter)
                return (beg, en)) (\_ shift' (beg, en) -> do
                    candy' <- readIDE candy
                    sTxt   <- getCandylessPart candy' descriptionBuffer beg en
                    unless (T.null sTxt) $ do
                        rect <- getIterLocation descriptionView en
                        bx   <- getRectangleX rect
                        by   <- getRectangleY rect
                        (x, y) <- bufferToWindowCoords descriptionView (fromIntegral bx, fromIntegral by)
                        getWindow descriptionView >>= \case
                            Nothing -> return ()
                            Just drawWindow -> do
                                (_, ox, oy)  <- windowGetOrigin drawWindow
                                triggerEventIDE_ (SelectInfo (SymbolEvent sTxt Nothing True shift' (ox + fromIntegral x, oy + fromIntegral y)))
                    )

        scrolledWindowSetPolicy sw PolicyTypeAutomatic PolicyTypeAutomatic

        --openType
        currentDescr' <- liftIO $ newIORef idDescr
        cids1 <- onPopulatePopup descriptionView $ \ menu -> do
            ideR <- ask
            populatePopupMenu ideR currentDescr' menu
        let info = IDEInfo sw currentDescr' descriptionView
        -- ids5 <- sv `onLookupInfo` selectInfo descriptionView       -- obsolete by hyperlinks
        cids2 <- descriptionView `afterFocusIn` makeActive info
        return (Just info, cids1 ++ cids2)


-- | Get the Info pane
getInfo :: IDEM IDEInfo
getInfo = forceGetPane (Right "*Info")


-- | Display the Info pane
showInfo :: IDEAction
showInfo = do
    pane <- getInfo
    displayPane pane False


-- | Open the source of the current symbol description
gotoSource :: IDEAction
gotoSource = do
    mbInfo <- getInfoCont
    case mbInfo of
        Nothing     ->  do  ideMessage Normal "gotoSource:noDefinition"
                            return ()
        Just info   ->  void (goToDefinition info)


-- | Select the symbol description in the module pane
gotoModule' :: IDEAction
gotoModule' = do
    mbInfo  <-  getInfoCont
    case mbInfo of
        Nothing     ->  return ()
        Just info   ->  void (triggerEventIDE (SelectIdent info))


-- | Replaces the symbol description and displays the info pane
setInfo :: Descr -> IDEAction
setInfo identifierDescr = do
    info <-  getInfo
    setInfo' info
    displayPane info False
  where
    setInfo' (info@IDEInfo{descriptionView = v}) = do
        oldDescr <- liftIO $ readIORef (currentDescr info)
        liftIO $ writeIORef (currentDescr info) (Just identifierDescr)
        tb <- getBuffer v
        setText tb (T.pack $ show (Present identifierDescr) ++ "\n")   -- EOL for text iters to work
        recordInfoHistory (Just identifierDescr) oldDescr


-- | Updates the style of the text buffer if it is opened
setInfoStyle :: IDEAction
setInfoStyle = getPane >>= setInfoStyle'
  where
    setInfoStyle' Nothing = return ()
    setInfoStyle' (Just IDEInfo{..}) = getBuffer descriptionView >>= updateStyle


-- | Try to get the symbol description of the Info pane
getInfoCont ::  IDEM (Maybe Descr)
getInfoCont = do
    mbPane <- getPane
    case mbPane of
        Nothing ->  return Nothing
        Just p  ->  liftIO $ readIORef (currentDescr p)


-- * GUI History


-- | Record the transition to the new description from the old
recordInfoHistory :: Maybe Descr -- ^ The new description
                  -> Maybe Descr -- ^ The old description
                  -> IDEAction
recordInfoHistory  descr oldDescr = do
    triggerEventIDE (RecordHistory
        (InfoElementSelected descr, InfoElementSelected oldDescr))
    return ()


-- | Replace the symbol description
replayInfoHistory :: Maybe Descr -- ^ If @Nothing@, the description is not replaced
                  -> IDEAction
replayInfoHistory mbDescr = forM_ mbDescr setInfo


-- | Open the documentation for the current symbol description
openDocu :: IDEAction
openDocu = do
    mbDescr <- getInfoCont
    case mbDescr of
        Nothing -> return ()
        Just descr -> do
            prefs' <- readIDE prefs
            openBrowser $ docuSearchURL prefs' <> T.pack (escapeURIString isAlphaNum (T.unpack $ dscName descr))


-- | Builds the context menu of the Info pane
populatePopupMenu :: MonadIO m => IDERef -> IORef (Maybe Descr) -> Menu -> m ()
populatePopupMenu ideR currentDescr' menu = do
    items <- containerGetChildren menu
    item0 <- menuItemNewWithLabel (__ "Goto Definition")
    onMenuItemActivate item0 $ reflectIDE gotoSource ideR
    item1 <- menuItemNewWithLabel (__ "Select Module")
    onMenuItemActivate item1 $ reflectIDE gotoModule' ideR
    item2 <- menuItemNewWithLabel (__ "Open Documentation")
    onMenuItemActivate item2 $ reflectIDE openDocu ideR
    menuShellAppend menu item0
    menuShellAppend menu item1
    menuShellAppend menu item2
    widgetShowAll menu
    mapM_ widgetHide $ take 2 (reverse items)
    return ()


