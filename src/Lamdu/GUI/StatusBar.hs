-- | The Lamdu status bar
{-# LANGUAGE FlexibleContexts #-}
module Lamdu.GUI.StatusBar
    ( module Lamdu.GUI.StatusBar.Common
    , make
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.Property (Property)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Draw as Draw
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import           Lamdu.Config (HasConfig)
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.GUI.IOTrans (IOTrans(..))
import qualified Lamdu.GUI.IOTrans as IOTrans
import qualified Lamdu.GUI.Settings as SettingsGui
import           Lamdu.GUI.StatusBar.Common
import qualified Lamdu.GUI.StatusBar.Common as StatusBar
import qualified Lamdu.GUI.VersionControl as VersionControlGUI
import qualified Lamdu.GUI.VersionControl.Config as VCConfig
import           Lamdu.Settings (Settings)
import qualified Lamdu.Themes as Themes
import qualified Lamdu.VersionControl.Actions as VCActions

import           Lamdu.Prelude

make ::
    ( MonadReader env m, MonadTransaction n m
    , TextEdit.HasStyle env, Theme.HasTheme env, Hover.HasStyle env
    , GuiState.HasState env, Element.HasAnimIdPrefix env
    , VCConfig.HasConfig env, VCConfig.HasTheme env, Spacer.HasStdSpacing env
    , HasConfig env
    ) =>
    StatusWidget (IOTrans n) ->
    [Themes.Selection] -> Property IO Settings ->
    Widget.R -> VCActions.Actions n (IOTrans n) ->
    m (StatusWidget (IOTrans n))
make gotoDefinition themeNames settingsProp width vcActions =
    do
        branchChoice <-
            VersionControlGUI.makeBranchSelector
            IOTrans.liftTrans transaction vcActions
        branchSelector <- StatusBar.makeStatusWidget "Branch" branchChoice

        statusWidgets <-
            SettingsGui.makeStatusWidgets themeNames settingsProp
            <&> SettingsGui.hoist IOTrans.liftIO

        theTheme <- Lens.view Theme.theme
        bgColor <-
            Draw.backgroundColor ?? theTheme ^. Theme.statusBar . Theme.statusBarBGColor
        StatusBar.combine
            ??  [ statusWidgets ^. SettingsGui.annotationWidget
                , statusWidgets ^. SettingsGui.themeWidget
                , branchSelector
                , statusWidgets ^. SettingsGui.helpWidget
                ]
            <&> StatusBar.combineEdges width gotoDefinition
            <&> StatusBar.widget . Align.tValue . Element.width .~ width
            <&> StatusBar.widget %~ bgColor
