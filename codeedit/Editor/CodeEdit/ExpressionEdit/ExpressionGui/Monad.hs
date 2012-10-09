{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell #-}
module Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad
  ( ExprGuiRM, run
  -- OTransaction wrappers:
  , otransaction, transaction, atEnv
  , getP, assignCursor, assignCursorPrefix
  --
  , ask
  -- 
  , AccessedVars, markVariablesAsUsed, usedVariables
  , withParamName, NameSource(..)
  , withNameFromVarRef
  , getDefName
  ) where

import Control.Applicative (Applicative, liftA2)
import Control.Monad (liftM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.RWS (RWST, runRWST)
import Data.Map (Map)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.OTransaction (OTransaction)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Trans.RWS as RWS
import qualified Data.Map as Map
import qualified Data.Store.Guid as Guid
import qualified Data.Store.IRef as IRef
import qualified Editor.Anchors as Anchors
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.OTransaction as OT
import qualified Graphics.UI.Bottle.Widget as Widget

type AccessedVars = [Guid]

data NameGenState = NameGenState
  { ngUnusedNames :: [String]
  , ngUsedNames :: Map Guid String
  }

data Askable r = Askable
  { _aNameGenState :: NameGenState
  , _aData :: r
  }
LensTH.makeLenses ''Askable

newtype ExprGuiRM r m a = ExprGuiRM
  { _varAccess :: RWST (Askable r) AccessedVars () (OTransaction ViewTag m) a }
  deriving (Functor, Applicative, Monad)
LensTH.makeLenses ''ExprGuiRM

atEnv :: Monad m => (OT.Env -> OT.Env) -> ExprGuiRM r m a -> ExprGuiRM r m a
atEnv = Lens.over varAccess . RWS.mapRWST . OT.atEnv

ask :: Monad m => ExprGuiRM r m r
ask = ExprGuiRM . RWS.asks $ Lens.view aData

run :: Monad m => r -> ExprGuiRM r m a -> OTransaction ViewTag m a
run r (ExprGuiRM action) =
  liftM f $ runRWST action (Askable initialNameGenState r) ()
  where
    f (x, _, _) = x

otransaction :: Monad m => OTransaction ViewTag m a -> ExprGuiRM r m a
otransaction = ExprGuiRM . lift

transaction :: Monad m => Transaction ViewTag m a -> ExprGuiRM r m a
transaction = otransaction . OT.transaction

getP :: Monad m => Anchors.MkProperty ViewTag m a -> ExprGuiRM r m a
getP = transaction . Anchors.getP

assignCursor :: Monad m => Widget.Id -> Widget.Id -> ExprGuiRM r m a -> ExprGuiRM r m a
assignCursor x y = atEnv $ OT.envAssignCursor x y

assignCursorPrefix :: Monad m => Widget.Id -> Widget.Id -> ExprGuiRM r m a -> ExprGuiRM r m a
assignCursorPrefix x y = atEnv $ OT.envAssignCursorPrefix x y

-- Used vars:

usedVariables
  :: Monad m
  => ExprGuiRM r m a -> ExprGuiRM r m (a, [Guid])
usedVariables = Lens.over varAccess RWS.listen

markVariablesAsUsed :: Monad m => AccessedVars -> ExprGuiRM r m ()
markVariablesAsUsed = ExprGuiRM . RWS.tell

-- Auto-generating names

initialNameGenState :: NameGenState
initialNameGenState =
  NameGenState names Map.empty
  where
    alphabet = map (:[]) ['a'..'z']
    names = alphabet ++ liftA2 (++) names alphabet

withNewName :: Monad m => Guid -> (String -> ExprGuiRM r m a) -> ExprGuiRM r m a
withNewName guid useNewName = do
  nameGen <- ExprGuiRM . RWS.asks $ Lens.view aNameGenState
  let
    (name : nextNames) = ngUnusedNames nameGen
    newNameGen = nameGen
      { ngUnusedNames = nextNames
      , ngUsedNames = Map.insert guid name $ ngUsedNames nameGen
      }
  ExprGuiRM .
    (RWS.local . Lens.set aNameGenState) newNameGen .
    Lens.view varAccess $ useNewName name

data NameSource = AutoGeneratedName | StoredName

withParamName :: Monad m => Guid -> ((NameSource, String) -> ExprGuiRM r m a) -> ExprGuiRM r m a
withParamName guid useNewName = do
  storedName <- transaction . Anchors.getP $ Anchors.assocNameRef guid
  -- TODO: maybe use Maybe?
  if null storedName
    then do
      existingName <-
        ExprGuiRM $ RWS.asks (Map.lookup guid . ngUsedNames . Lens.view aNameGenState)
      let useGenName = useNewName . (,) AutoGeneratedName
      case existingName of
        Nothing -> withNewName guid useGenName
        Just name -> useGenName name
    else useNewName (StoredName, storedName)

getDefName :: Monad m => Guid -> ExprGuiRM r m (NameSource, String)
getDefName guid = do
  storedName <- transaction . Anchors.getP $ Anchors.assocNameRef guid
  return $
    if null storedName
    then (AutoGeneratedName, (("anon_"++) . take 6 . Guid.asHex) guid)
    else (StoredName, storedName)

withNameFromVarRef ::
  Monad m => Sugar.GetVariable -> ((NameSource, String) -> ExprGuiRM r m a) -> ExprGuiRM r m a
withNameFromVarRef (Sugar.GetParameter g) useName = withParamName g useName
withNameFromVarRef (Sugar.GetDefinition defI) useName =
  useName =<< getDefName (IRef.guid defI)
