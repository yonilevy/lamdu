{-# LANGUAGE OverloadedStrings #-}

module Editor.CodeEdit.ExpressionEdit.FuncEdit
  (make, makeParamNameEdit, addJumpToRHS, makeResultEdit, makeParamsAndResultEdit) where

import Control.Monad (liftM)
import Data.Monoid (mempty, mconcat)
import Data.Store.Guid (Guid)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui, ExprGuiM, WidgetT)
import Editor.MonadF (MonadF)
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Editor.CodeEdit.Parens as Parens
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.ITransaction as IT
import qualified Editor.OTransaction as OT
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

paramFDConfig :: FocusDelegator.Config
paramFDConfig = FocusDelegator.Config
  { FocusDelegator.startDelegatingKey = E.ModKey E.noMods E.KeyEnter
  , FocusDelegator.startDelegatingDoc = "Change parameter name"
  , FocusDelegator.stopDelegatingKey = E.ModKey E.noMods E.KeyEsc
  , FocusDelegator.stopDelegatingDoc = "Stop changing name"
  }

makeParamNameEdit
  :: MonadF m
  => (ExprGuiM.NameSource, String) -> Guid
  -> ExprGuiM m (WidgetT m)
makeParamNameEdit name ident =
  ExpressionGui.wrapDelegated paramFDConfig FocusDelegator.NotDelegating id
  (ExprGuiM.atEnv (OT.setTextColor Config.paramOriginColor) .
   ExpressionGui.makeNameEdit name ident) $ WidgetIds.fromGuid ident

addJumpToRHS
  :: MonadF m => (E.Doc, Sugar.Expression m) -> WidgetT m -> WidgetT m
addJumpToRHS (rhsDoc, rhs) =
  Widget.weakerEvents .
  Widget.keysEventMapMovesCursor Config.jumpLHStoRHSKeys ("Jump to " ++ rhsDoc) $
  return rhsId
  where
    rhsId = WidgetIds.fromGuid $ Sugar.rGuid rhs

-- exported for use in definition sugaring.
makeParamEdit
  :: MonadF m
  => (E.Doc, Sugar.Expression m)
  -> (ExprGuiM.NameSource, String)
  -> Widget.Id
  -> Sugar.FuncParam m (Sugar.Expression m)
  -> ExprGuiM m (ExpressionGui m)
makeParamEdit rhs name prevId param =
  (liftM . ExpressionGui.atEgWidget)
  (addJumpToRHS rhs . Widget.weakerEvents paramEventMap) .
  assignCursor $ do
    paramTypeEdit <- ExpressionGui.makeSubexpresion $ Sugar.fpType param
    paramNameEdit <- makeParamNameEdit name ident
    return . ExpressionGui.addType ExpressionGui.HorizLine (WidgetIds.fromGuid ident)
      [ExpressionGui.egWidget paramTypeEdit] $
      ExpressionGui.fromValueWidget paramNameEdit
  where
    assignCursor =
      case Sugar.fpHiddenLambdaGuid param of
      Nothing -> id
      Just g ->
        ExprGuiM.assignCursor (WidgetIds.fromGuid g) $ WidgetIds.fromGuid ident
    ident = Sugar.fpGuid param
    paramEventMap = mconcat
      [ paramDeleteEventMap Config.delForwardKeys "" id
      , paramDeleteEventMap Config.delBackwordKeys " backwards" (const prevId)
      , paramAddNextEventMap
      ]
    paramAddNextEventMap =
      maybe mempty
      (Widget.keysEventMapMovesCursor Config.addNextParamKeys "Add next parameter" .
       liftM (FocusDelegator.delegatingId . WidgetIds.fromGuid) .
       IT.transaction . Sugar.itemAddNext) $
      Sugar.fpMActions param
    paramDeleteEventMap keys docSuffix onId =
      maybe mempty
      (Widget.keysEventMapMovesCursor keys ("Delete parameter" ++ docSuffix) .
       liftM (onId . WidgetIds.fromGuid) .
       IT.transaction . Sugar.itemDelete) $
      Sugar.fpMActions param

makeResultEdit
  :: MonadF m
  => [Widget.Id]
  -> Sugar.Expression m
  -> ExprGuiM m (ExpressionGui m)
makeResultEdit lhs result =
  liftM ((ExpressionGui.atEgWidget . Widget.weakerEvents) jumpToLhsEventMap) $
  ExpressionGui.makeSubexpresion result
  where
    lastParam = case lhs of
      [] -> error "makeResultEdit given empty LHS"
      xs -> last xs
    jumpToLhsEventMap =
      Widget.keysEventMapMovesCursor Config.jumpRHStoLHSKeys "Jump to last param" $
      return lastParam

make
  :: MonadF m
  => Sugar.HasParens
  -> Sugar.Func m (Sugar.Expression m)
  -> Widget.Id
  -> ExprGuiM m (ExpressionGui m)
make hasParens (Sugar.Func params body) =
  ExpressionGui.wrapParenify hasParens Parens.addHighlightedTextParens $ \myId ->
  ExprGuiM.assignCursor myId bodyId $ do
    lambdaLabel <-
      liftM ExpressionGui.fromValueWidget .
      ExprGuiM.atEnv (OT.setTextSizeColor Config.lambdaTextSize Config.lambdaColor) .
      ExprGuiM.otransaction . BWidgets.makeLabel "λ" $ Widget.toAnimId myId
    rightArrowLabel <-
      liftM ExpressionGui.fromValueWidget .
      ExprGuiM.atEnv (OT.setTextSizeColor Config.rightArrowTextSize Config.rightArrowColor) .
      ExprGuiM.otransaction . BWidgets.makeLabel "→" $ Widget.toAnimId myId
    (paramsEdits, bodyEdit) <-
      makeParamsAndResultEdit lhs ("Func Body", body) myId params
    return . ExpressionGui.hboxSpaced $
      lambdaLabel : paramsEdits ++ [ rightArrowLabel, bodyEdit ]
  where
    bodyId = WidgetIds.fromGuid $ Sugar.rGuid body
    lhs = map (WidgetIds.fromGuid . Sugar.fpGuid) params

makeParamsAndResultEdit ::
  MonadF m =>
  [Widget.Id] ->
  (E.Doc, Sugar.Expression m) ->
  Widget.Id ->
  [Sugar.FuncParam m (Sugar.Expression m)] ->
  ExprGuiM m ([ExpressionGui m], ExpressionGui m)
makeParamsAndResultEdit lhs rhs@(_, result) =
  go
  where
    go _ [] = liftM ((,) []) $ makeResultEdit lhs result
    go prevId (param:params) = do
      let guid = Sugar.fpGuid param
      (name, (paramEdits, resultEdit)) <-
        ExprGuiM.withParamName guid $
        \name -> liftM ((,) name) $ go (WidgetIds.fromGuid guid) params
      paramEdit <- makeParamEdit rhs name prevId param
      return (paramEdit : paramEdits, resultEdit)
