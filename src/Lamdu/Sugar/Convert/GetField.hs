{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.Sugar.Convert.GetField
    ( convert
    ) where

import qualified Control.Lens as Lens
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Convert.Tag (convertTag)
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import qualified Revision.Deltum.Property as Property

import           Lamdu.Prelude

convertGetFieldParam ::
    Monad m =>
    V.GetField (Val a) -> Input.Payload m b ->
    ConvertM m (Maybe (ExpressionU m b))
convertGetFieldParam (V.GetField recExpr tag) exprPl =
    do
        tagParamInfos <- Lens.view (ConvertM.scScopeInfo . ConvertM.siTagParamInfos)
        do
            paramInfo <- tagParamInfos ^? Lens.ix tag . ConvertM._TagFieldParam
            param <- recExpr ^? ExprLens.valVar
            guard $ param == ConvertM.tpiFromParameters paramInfo
            GetParam ParamRef
                { _pNameRef = NameRef
                  { _nrName = nameWithContext param tag
                  , _nrGotoDefinition = ConvertM.tpiJumpTo paramInfo & pure
                  }
                , _pBinderMode = NormalBinder
                } & BodyGetVar & Just
            & Lens._Just %%~ addActions exprPl

convertGetFieldNonParam ::
    (Monad m, Monoid a) =>
    V.GetField (Val (Input.Payload m a)) -> Input.Payload m a ->
    ConvertM m (ExpressionU m a)
convertGetFieldNonParam (V.GetField recExpr tag) exprPl =
    GetField
    <$> ConvertM.convertSubexpression recExpr
    <*> do
            protectedSetToVal <- ConvertM.typeProtectedSetToVal
            let setTag newTag =
                    do
                        V.GetField recExprI newTag & V.BGetField & ExprIRef.writeValBody valI
                        protectedSetToVal recExprStored recExprI & void
            convertTag tag nameWithoutContext mempty (EntityId.ofTag (exprPl ^. Input.entityId)) setTag
    <&> BodyGetField
    >>= addActions exprPl
    where
        valI = exprPl ^. Input.stored . Property.pVal
        recExprStored = recExpr ^. Val.payload . Input.stored
        recExprI = recExprStored ^. Property.pVal

convert ::
    (Monad m, Monoid a) =>
    V.GetField (Val (Input.Payload m a)) ->
    Input.Payload m a ->
    ConvertM m (ExpressionU m a)
convert getField exprPl =
    convertGetFieldParam getField exprPl
    >>= maybe (convertGetFieldNonParam getField exprPl) pure
