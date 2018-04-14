{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.WebKit.Output
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  maintainer@leksah.org
-- Stability   :  provisional
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

module IDE.Pane.WebKit.Output (
    IDEOutput(..)
  , OutputState(..)
  , getOutputPane
  , setOutput
  , loadOutputUri
  , loadOutputHtmlFile
) where

import Graphics.UI.Frame.Panes
       (RecoverablePane(..), PanePath, RecoverablePane, Pane(..))
import IDE.Utils.GUIUtils
import Data.Typeable (Typeable)
import IDE.Core.Types (IDEAction, IDEM, IDE(..))
import Control.Monad.IO.Class (MonadIO(..))
import Graphics.UI.Frame.ViewFrame (getNotebook)
import IDE.Core.State
       (modifyIDE_, postSyncIDE, reifyIDE, leksahOrPackageDir)
import IDE.Core.State (reflectIDE)
import Graphics.UI.Editor.Basics (Connection(..))
import Text.Show.Pretty
       (HtmlOpts(..), defaultHtmlOpts, valToHtmlPage, parseValue, getDataDir)
import System.FilePath ((</>))
import IDE.Pane.WebKit.Inspect (getInspectPane, IDEInspect(..))
import Data.IORef (writeIORef, newIORef, readIORef, IORef)
import Control.Applicative ((<$>))
import System.Log.Logger (debugM)
import Data.Text (Text)
import qualified Data.Text as T (unpack, pack)
import GI.Gtk.Objects.Box (boxNew, Box(..))
import GI.Gtk.Objects.Entry
       (entryGetText, onEntryActivate, entrySetText, entryNew, Entry(..))
#ifdef MIN_VERSION_gi_webkit2
import GI.WebKit2.Objects.WebView
       (webViewReload, webViewGetUri, webViewLoadHtml,
        webViewGetInspector, setWebViewSettings, webViewGetSettings,
        onWebViewLoadChanged, webViewLoadUri, onWebViewContextMenu,
        webViewGoBack, webViewNew,
        setWebViewZoomLevel, getWebViewZoomLevel, WebView(..))
import GI.WebKit2.Objects.Settings
       (settingsSetEnableDeveloperExtras, settingsSetAllowFileAccessFromFileUrls)
#else
import GI.WebKit.Objects.WebView
       (webViewReload, webViewGetUri, webViewLoadString,
        webViewGetInspector, setWebViewSettings, getWebViewSettings,
        onWebViewLoadCommitted, webViewLoadUri, onWebViewPopulatePopup,
        webViewGoBack, webViewZoomOut, webViewZoomIn, webViewNew,
        setWebViewZoomLevel, getWebViewZoomLevel, WebView(..))
import GI.WebKit.Objects.WebFrame (webFrameGetUri)
import GI.WebKit.Objects.WebSettings
       (setWebSettingsEnableDeveloperExtras)
import GI.WebKit.Objects.WebInspector
       (onWebInspectorInspectWebView)
#endif
import GI.Gtk.Objects.Widget
       (onWidgetKeyPressEvent, afterWidgetFocusInEvent, toWidget)
import GI.Gtk.Objects.ScrolledWindow
       (scrolledWindowSetPolicy, scrolledWindowSetShadowType,
        scrolledWindowNew)
import GI.Gtk.Objects.Adjustment (noAdjustment)
import GI.Gtk.Enums (PolicyType(..), ShadowType(..), Orientation(..))
import Graphics.UI.Editor.Parameters (Packing(..), boxPackStart')
import GI.Gtk.Objects.Container (containerAdd)
import GI.Gdk (getEventKeyState, getEventKeyKeyval, keyvalName)
import GI.Gdk.Flags (ModifierType(..))
import GI.Gtk.Objects.ToggleAction
       (setToggleActionActive, toggleActionNew)
import GI.Gtk.Objects.Action (actionCreateMenuItem)
import GI.Gtk.Objects.MenuItem
       (MenuItem(..), onMenuItemActivate, toMenuItem)
import GI.Gtk.Objects.MenuShell (menuShellAppend)
import Data.GI.Base.ManagedPtr (unsafeCastTo)
import qualified Data.Text.IO as T (readFile)
import Data.Aeson (FromJSON, ToJSON, FromJSON)
import GHC.Generics (Generic)

data IDEOutput = IDEOutput {
    vbox          :: Box
  , uriEntry      :: Entry
  , webView       :: WebView
  , alwaysHtmlRef :: IORef Bool
--  , outState      :: IORef OutputState
} deriving Typeable

data OutputState = OutputState {
    zoom :: Double
  , alwaysHtml :: Bool
} deriving(Eq,Ord,Read,Show,Typeable,Generic)

instance ToJSON OutputState
instance FromJSON OutputState

instance Pane IDEOutput IDEM
    where
    primPaneName _  =   "Out"
    getAddedIndex _ =   0
    getTopWidget    =   liftIO . toWidget . vbox
    paneId b        =   "*Out"

instance RecoverablePane IDEOutput OutputState IDEM where
    saveState p = do
        zoom <- fmap realToFrac <$> getWebViewZoomLevel $ webView p
        alwaysHtml <- liftIO . readIORef $ alwaysHtmlRef p
        return (Just OutputState{..})
    recoverState pp OutputState {..} = do
        nb     <- getNotebook pp
        mbPane <- buildPane pp nb builder
        case mbPane of
            Nothing -> return ()
            Just p  -> do
                setWebViewZoomLevel (webView p) (realToFrac zoom)
                liftIO $ writeIORef (alwaysHtmlRef p) alwaysHtml
        return mbPane
    builder pp nb windows = reifyIDE $ \ ideR -> do
        vbox <- boxNew OrientationVertical 0
        uriEntry <- entryNew
        entrySetText uriEntry "http://"
        scrolledView <- scrolledWindowNew noAdjustment noAdjustment
        scrolledWindowSetShadowType scrolledView ShadowTypeIn
        boxPackStart' vbox uriEntry PackNatural 0
        boxPackStart' vbox scrolledView PackGrow 0

        webView <- webViewNew
        alwaysHtmlRef <- newIORef False
        containerAdd scrolledView webView

        scrolledWindowSetPolicy scrolledView PolicyTypeAutomatic PolicyTypeAutomatic
        let out = IDEOutput {..}

        cid1 <- ConnectC webView <$> afterWidgetFocusInEvent webView (\e -> do
            liftIO $ reflectIDE (makeActive out) ideR
            return True)

--        webView `set` [webViewZoomLevel := 2.0]
        cid2 <- ConnectC webView <$> onWidgetKeyPressEvent webView (\e -> do
            key <- getEventKeyKeyval e >>= keyvalName
            mod <- getEventKeyState e
            case (key, mod) of
                (Just "plus", [ModifierTypeShiftMask,ModifierTypeControlMask]) -> do
                    zoom <- getWebViewZoomLevel webView
                    setWebViewZoomLevel webView (zoom * 1.25)
                    return True
                (Just "minus",[ModifierTypeControlMask]) -> do
                    zoom <- getWebViewZoomLevel webView
                    setWebViewZoomLevel webView (zoom * 0.8)
                    return True
                (Just "BackSpace", [ModifierTypeShiftMask]) -> webViewGoBack  webView >> return True
                _                         -> return False)

        -- TODO
#ifndef MIN_VERSION_gi_webkit2
        cid3 <- ConnectC webView <$> onWebViewPopulatePopup webView (\ menu -> do
            alwaysHtml <- readIORef alwaysHtmlRef
            action <- toggleActionNew "AlwaysHTML" (Just $ __"Always HTML") Nothing Nothing
            item <- actionCreateMenuItem action >>= unsafeCastTo MenuItem
            onMenuItemActivate item $ writeIORef alwaysHtmlRef $ not alwaysHtml
            setToggleActionActive action alwaysHtml
            menuShellAppend menu item
            return ())
#endif

        cid4 <- ConnectC uriEntry <$> onEntryActivate uriEntry (do
            uri <- entryGetText uriEntry
            webViewLoadUri webView uri
            (`reflectIDE` ideR) $ modifyIDE_ (\ide -> ide {autoURI = Just uri}))

#ifndef MIN_VERSION_gi_webkit2
        cid5 <- ConnectC webView <$> onWebViewLoadCommitted webView (\ frame -> do
            uri <- webFrameGetUri frame
            valueUri <- getValueUri
            if uri /= valueUri
                then do
                    entrySetText uriEntry uri
                    (`reflectIDE` ideR) $ modifyIDE_ (\ide -> ide {autoURI = Just uri})
                else
                    (`reflectIDE` ideR) $ modifyIDE_ (\ide -> ide {autoURI = Nothing}))
#endif

        cid6 <- ConnectC uriEntry <$> afterWidgetFocusInEvent uriEntry (\e -> do
            liftIO $ reflectIDE (makeActive out) ideR
            return True)

#ifdef MIN_VERSION_gi_webkit2
        settings <- webViewGetSettings webView
        settingsSetEnableDeveloperExtras settings True
        settingsSetAllowFileAccessFromFileUrls settings True
#else
        settings <- getWebViewSettings webView
        setWebSettingsEnableDeveloperExtras settings True
#endif
        setWebViewSettings webView settings
        inspector <- webViewGetInspector webView

#ifndef MIN_VERSION_gi_webkit2
        cid7 <- ConnectC inspector <$> onWebInspectorInspectWebView inspector (\view -> (`reflectIDE` ideR) $ do
            inspectPane <- getInspectPane Nothing
            displayPane inspectPane False
            return $ inspectView inspectPane)
#endif

#ifdef MIN_VERSION_gi_webkit2
        return (Just out, [cid1, cid2, cid4, cid6])
#else
        return (Just out, [cid1, cid2, cid3, cid4, cid5, cid6, cid7])
#endif


getOutputPane :: Maybe PanePath -> IDEM IDEOutput
getOutputPane Nothing    = forceGetPane (Right "*Out")
getOutputPane (Just pp)  = forceGetPane (Left pp)

getValueUri :: MonadIO m => m Text
getValueUri = do
    dataDir <- liftIO $ map fixSep <$> leksahOrPackageDir "pretty-show" getDataDir
    return . T.pack $ "file://"
        ++ (case dataDir of
                ('/':_) -> dataDir
                _       -> '/':dataDir)
        ++ "/value.html"
  where
    fixSep '\\' = '/'
    fixSep x = x

setOutput :: Text -> Text -> IDEAction
setOutput command str =
     do out <- getOutputPane Nothing
        entrySetText (uriEntry out) (T.pack $ show command)
        uri <- getValueUri
        alwaysHtml <- liftIO . readIORef $ alwaysHtmlRef out
        let view = webView out
            html = case (alwaysHtml, parseValue $ T.unpack str) of
                        (False, Just value) -> T.pack $ valToHtmlPage defaultHtmlOpts value
                        _                   -> str
#ifdef MIN_VERSION_gi_webkit2
        webViewLoadHtml view html (Just uri)
#else
        webViewLoadString view html "text/html" "UTF-8" uri
#endif

loadOutputUri :: FilePath -> IDEAction
loadOutputUri uri =
     do out <- getOutputPane Nothing
        let view = webView out
        entrySetText (uriEntry out) (T.pack uri)
        currentUri <- webViewGetUri view
        if Just (T.pack uri) == currentUri
            then webViewReload view
            else webViewLoadUri view (T.pack uri)

loadOutputHtmlFile :: FilePath -> IDEAction
loadOutputHtmlFile file = do
    out <- getOutputPane Nothing
    let view = webView out
    html <- liftIO $ T.readFile file
    let uri = "file:///" ++ file
    entrySetText (uriEntry out) (T.pack uri)
    currentUri <- webViewGetUri view
#ifdef MIN_VERSION_gi_webkit2
    webViewLoadHtml view html (Just $ T.pack uri)
#else
    webViewLoadString view html "text/html" "UTF-8" uri
#endif
--    if Just (T.pack uri) == currentUri
--        then webViewReload view
--        else webViewLoadUri view (T.pack uri)

