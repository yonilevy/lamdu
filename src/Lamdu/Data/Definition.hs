{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Data.Definition
    ( FFIName(..)
    , Expr(..), expr, exprFrozenDeps
    , Body(..), _BodyExpr, _BodyBuiltin
    , Definition(..), defBody, defType, defPayload
    , pruneDefExprDeps
    ) where

import qualified Control.Lens as Lens
import           Data.Binary (Binary(..))
import           Data.Map.Extended (setMapIntersection)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Lamdu.Calc.Lens as ExprLens
import           Lamdu.Calc.Term (Val)
import           Lamdu.Calc.Type.Scheme (Scheme)
import           Lamdu.Infer (Dependencies)
import qualified Lamdu.Infer as Infer

import           Lamdu.Prelude

data FFIName = FFIName
    { fModule :: [Text]
    , fName :: Text
    } deriving (Generic, Eq, Ord)

instance Show FFIName where
    show (FFIName path name) =
        mconcat (path <&> (<> ".")) <> name & Text.unpack

data Expr valExpr = Expr
    { _expr :: valExpr
    , _exprFrozenDeps :: Dependencies
    } deriving (Generic, Show, Functor, Foldable, Traversable, Eq, Ord)

data Body valExpr
    = BodyExpr (Expr valExpr)
    | BodyBuiltin FFIName
    deriving (Generic, Show, Functor, Foldable, Traversable, Eq, Ord)

data Definition valExpr a = Definition
    { _defBody :: Body valExpr
    , _defType :: Scheme -- TODO: typeExpr
    , _defPayload :: a
    } deriving (Generic, Functor, Foldable, Traversable, Eq, Ord)

instance Binary FFIName
instance Binary valExpr => Binary (Expr valExpr)
instance Binary valExpr => Binary (Body valExpr)
instance (Binary valExpr, Binary a) => Binary (Definition valExpr a)

Lens.makePrisms ''Body
Lens.makeLenses ''Definition
Lens.makeLenses ''Expr

-- Prune dependencies of an Expr after edits.
pruneDefExprDeps :: Expr (Val a) -> Infer.Dependencies
pruneDefExprDeps defExpr =
    defExpr ^. exprFrozenDeps
    & Infer.depsGlobalTypes %~ setMapIntersection valVars
    & Infer.depsNominals %~ setMapIntersection valNoms
    where
        val = defExpr ^. expr
        valVars = val ^..  ExprLens.valGlobals mempty & Set.fromList
        valNoms = val ^.. ExprLens.valNominals & Set.fromList
