{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell #-}

-- | View and Branch have a cyclic dependency. This module
-- | contains the parts of both that both may depend on, to avoid the
-- | cycle.
module Revision.Deltum.Rev.ViewBranchInternal
    ( ViewData(..), vdBranch
    , View(..)
    , BranchData(..), brVersion, brViews
    , Branch(..)
    , moveView, applyChangesToView, makeViewKey
    )
where

import qualified Control.Lens as Lens
import           Data.Binary (Binary(..))
import           Data.UUID.Types (UUID)
import qualified Data.UUID.Utils as UUIDUtils
import           Revision.Deltum.IRef (IRef)
import qualified Revision.Deltum.IRef as IRef
import           Revision.Deltum.Rev.Change (Change)
import qualified Revision.Deltum.Rev.Change as Change
import           Revision.Deltum.Rev.Version (Version)
import qualified Revision.Deltum.Rev.Version as Version
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction

import           Lamdu.Prelude

-- This key is XOR'd with object keys to yield the IRef to each
-- object's current version ref:
newtype View m = View (IRef m (ViewData m))
    deriving (Eq, Ord, Binary, Show, Read)

data BranchData m = BranchData
    { _brVersion :: Version m
    , _brViews :: [View m]
    } deriving (Eq, Ord, Read, Show, Generic)
instance Binary (BranchData m)

newtype Branch m = Branch { unBranch :: IRef m (BranchData m) }
    deriving (Eq, Ord, Read, Show, Binary)

newtype ViewData m = ViewData { _vdBranch :: Branch m }
    deriving (Eq, Ord, Show, Read, Binary)

Lens.makeLenses ''BranchData
Lens.makeLenses ''ViewData

type T = Transaction

-- | moveView must be given the correct source of the movement
-- | or it will result in undefined results!
moveView :: Monad m => View m -> Version m -> Version m -> T m ()
moveView vm =
    Version.walk applyBackward applyForward
    where
        applyForward = apply Change.newValue
        applyBackward = apply Change.oldValue
        apply changeDir = applyChangesToView vm changeDir . Version.changes

makeViewKey :: View m -> Change.Key -> UUID
makeViewKey (View iref) = UUIDUtils.combine . IRef.uuid $ iref

applyChangesToView ::
    Monad m => View m -> (Change -> Maybe Change.Value) ->
    [Change] -> T m ()
applyChangesToView vm changeDir = traverse_ applyChange
    where
        applyChange change =
            setValue
            (makeViewKey vm $ Change.objectKey change)
            (changeDir change)
        setValue key Nothing = Transaction.delete key
        setValue key (Just value) = Transaction.insertBS key value
