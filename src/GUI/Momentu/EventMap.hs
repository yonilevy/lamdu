{-# LANGUAGE TemplateHaskell, FlexibleContexts, PatternGuards, NoMonomorphismRestriction #-}
module GUI.Momentu.EventMap
    ( KeyEvent(..)
    , InputDoc, Subtitle, Doc(..), docStrs
    , Clipboard
    , MaybeWantsClipboard(..), _Doesn'tWantClipboard, _WantsClipboard
    , Event(..)
    , EventMap, lookup
    , emDocs
    , charEventMap, allChars
    , charGroup
    , keyEventMap, keyPress, keyPresses, keyPressOrRepeat
    , keysEventMap
    , keysEventMapMovesCursor
    , pasteOnKey
    , dropEventMap
    , deleteKey, deleteKeys
    , filterChars, filter, mapMaybe
    , -- exported for Tests
      emKeyMap, dhDoc, dhFileLocation, dhHandler
    ) where

import           Control.Applicative ((<|>))
import qualified Control.Lens.Extended as Lens
import           Data.Char (isAscii)
import           Data.Foldable (asum)
import qualified Data.Map as Map
import           Data.Maybe (listToMaybe)
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import           Data.String (IsString(..))
import           GHC.Stack (CallStack, callStack, withFrozenCallStack)
import qualified GUI.Momentu.Main.Events as Events
import           GUI.Momentu.MetaKey (MetaKey, toModKey)
import           GUI.Momentu.ModKey (ModKey(..))
import qualified GUI.Momentu.ModKey as ModKey
import           GUI.Momentu.State (Gui)
import qualified GUI.Momentu.State as State
import           GUI.Momentu.Widget.Id (Id)
import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.UI.GLFW.Utils as GLFWUtils
import qualified Lamdu.Prelude as Prelude

import           Lamdu.Prelude hiding (lookup, filter)

{-# ANN module ("HLint: ignore Use camelCase"::String) #-}

data KeyEvent = KeyEvent ModKey.KeyState ModKey
    deriving (Generic, Show, Eq, Ord)

type Clipboard = Text

type Subtitle = Text

newtype Doc = Doc
    { _docStrs :: [Subtitle]
    } deriving (Generic, Eq, Ord, Show)
Lens.makeLenses ''Doc

data DocHandler a = DocHandler
    { _dhDoc :: Doc
    , _dhFileLocation :: CallStack
    , _dhHandler :: a
    } deriving (Generic, Functor, Foldable, Traversable)
Lens.makeLenses ''DocHandler

type InputDoc = Text

-- AllCharsHandler always conflict with each other
data AllCharsHandler a = AllCharsHandler
    { __chInputDoc :: InputDoc
    , _chDocHandler :: DocHandler (Char -> Maybe a)
    } deriving (Generic, Functor)
Lens.makeLenses ''AllCharsHandler

chDocs :: Lens.IndexedTraversal' InputDoc (AllCharsHandler a) Doc
chDocs f (AllCharsHandler inputDoc docHandler) =
    AllCharsHandler inputDoc
    <$> dhDoc (Lens.indexed f inputDoc) docHandler

data CharGroupHandler a = CharGroupHandler
    { __cgMInputDoc :: Maybe InputDoc
    , _cgDocHandler :: DocHandler (Map Char a)
    } deriving (Generic, Functor)
Lens.makeLenses ''CharGroupHandler

cgDocs :: Lens.IndexedTraversal' InputDoc (CharGroupHandler a) Doc
cgDocs f (CharGroupHandler mInputDoc docHandler) =
    dhDoc (Lens.indexed f inputDoc) docHandler
    <&> CharGroupHandler mInputDoc
    where
        inputDoc = fromMaybe autoDoc mInputDoc
        autoDoc =
            docHandler ^.. dhHandler . Lens.ifolded . Lens.asIndex . Lens.filtered isAscii
            & show
            & fromString

-- File path (drag&)drop handler
data DropHandler a = DropHandler
    { __dropHandlerInputDoc :: InputDoc
    , _dropDocHandler :: DocHandler ([FilePath] -> Maybe a)
    } deriving (Generic, Functor)
Lens.makeLenses ''DropHandler

dropHandlerDocs :: Lens.IndexedTraversal' InputDoc (DropHandler a) Doc
dropHandlerDocs f (DropHandler inputDoc docHandler) =
    DropHandler inputDoc
    <$> dhDoc (Lens.indexed f inputDoc) docHandler

data MaybeWantsClipboard a
    = Doesn'tWantClipboard a
    | WantsClipboard (Clipboard -> Maybe a)
    deriving (Functor)
Lens.makePrisms ''MaybeWantsClipboard

type KeyMap a = Map KeyEvent (DocHandler (MaybeWantsClipboard a))

data EventMap a = EventMap
    { _emKeyMap :: KeyMap a
    , _emDropHandlers :: [DropHandler a]
    , _emCharGroupHandlers :: [CharGroupHandler a]
    , _emAllCharsHandler :: [AllCharsHandler a]
    } deriving (Generic, Functor)

prettyKeyEvent :: KeyEvent -> InputDoc
prettyKeyEvent (KeyEvent ModKey.KeyState'Pressed modKey) = ModKey.pretty modKey
prettyKeyEvent (KeyEvent ModKey.KeyState'Repeating modKey) = "Repeat " <> ModKey.pretty modKey
prettyKeyEvent (KeyEvent ModKey.KeyState'Released modKey) = "Depress " <> ModKey.pretty modKey

emDocs :: Lens.IndexedTraversal' InputDoc (EventMap a) Doc
emDocs f e =
    EventMap
    <$> (Lens.reindexed prettyKeyEvent Lens.itraversed <. dhDoc) f (_emKeyMap e)
    <*> (Lens.traverse .> dropHandlerDocs) f (_emDropHandlers e)
    <*> (Lens.traverse .> cgDocs) f (_emCharGroupHandlers e)
    <*> (Lens.traverse .> chDocs) f (_emAllCharsHandler e)

Lens.makeLenses ''EventMap

instance Semigroup (EventMap a) where
    (<>) = overrides

instance Monoid (EventMap a) where
    mempty = EventMap mempty mempty mempty mempty
    mappend = (<>)

overrides :: EventMap a -> EventMap a -> EventMap a
overrides
    x@(EventMap xMap xDropHandlers xCharGroups xMAllChars)
    (EventMap yMap yDropHandlers yCharGroups yMAllChars) =
    EventMap
    (xMap <> filteredYMap)
    (xDropHandlers ++ yDropHandlers)
    (xCharGroups ++ filteredYCharGroups)
    (xMAllChars ++ yMAllChars)
    where
        filteredYMap = filterByKey (not . isKeyConflict) yMap
        isKeyConflict (KeyEvent _ (ModKey mods key))
            | isCharMods mods =
                maybe False (isCharConflict x) $ GLFWUtils.charOfKey key
            | otherwise = False
        filteredYCharGroups =
            filterCharGroups (not . isCharConflict x) yCharGroups

filterCharGroups ::
    (Char -> Bool) ->
    [CharGroupHandler a] ->
    [CharGroupHandler a]
filterCharGroups f groups =
    groups
    <&> cgDocHandler . dhHandler %~ filterByKey f
    & Prelude.filter (not . Map.null . (^. cgDocHandler . dhHandler))

isCharConflict :: EventMap a -> Char -> Bool
isCharConflict x char =
    char `Map.member` (x ^. emCharGroupHandlers . traverse . cgDocHandler . dhHandler) ||
    ( x ^. emAllCharsHandler
    & Maybe.mapMaybe (($ char) . (^. chDocHandler . dhHandler))
    & not . null
    )

-- mapMaybe is a safer primitive to implement than filter because we
-- cannot forget to map any subcomponent.
mapMaybe :: (a -> Maybe b) -> EventMap a -> EventMap b
mapMaybe p (EventMap m dropHandlers charGroups mAllChars) =
    EventMap
    (m & Map.mapMaybe (dhHandler %%~ f))
    (dropHandlers <&> dropDocHandler %~ t)
    ((charGroups <&> cgDocHandler . dhHandler %~ Map.mapMaybe p)
        ^.. traverse . Lens.filteredBy (cgDocHandler . dhHandler . traverse))
    (mAllChars <&> chDocHandler %~ t)
    where
        t = dhHandler . Lens.mapped %~ (>>= p)
        f (Doesn'tWantClipboard val) = p val <&> Doesn'tWantClipboard
        f (WantsClipboard func) = (>>= p) . func & WantsClipboard & Just

filter :: (a -> Bool) -> EventMap a -> EventMap a
filter p =
    mapMaybe f
    where
        f x
            | p x = Just x
            | otherwise = Nothing

filterChars :: (Char -> Bool) -> EventMap a -> EventMap a
filterChars p val =
    val
    & emAllCharsHandler . Lens.traversed . chDocHandler . dhHandler %~ f
    & emCharGroupHandlers %~ filterCharGroups p
    where
        f handler c = do
            guard $ p c
            handler c

isCharMods :: GLFW.ModifierKeys -> Bool
isCharMods modKeys =
        not $ any ($ modKeys)
        [ GLFW.modifierKeysSuper
        , GLFW.modifierKeysControl
        , GLFW.modifierKeysAlt
        ]

filterByKey :: (k -> Bool) -> Map k v -> Map k v
filterByKey p = Map.filterWithKey (const . p)

deleteKey :: KeyEvent -> EventMap a -> EventMap a
deleteKey key = emKeyMap %~ Map.delete key

deleteKeys :: [KeyEvent] -> EventMap a -> EventMap a
deleteKeys = foldr ((.) . deleteKey) id

data Event
     = EventKey Events.KeyEvent
     | EventChar Char
     | EventDropPaths [FilePath]

lookup ::
    Applicative f =>
    f (Maybe Clipboard) -> Event -> EventMap a -> f (Maybe (DocHandler a))
lookup _ (EventDropPaths paths) x =
    map applyHandler (x ^. emDropHandlers) & asum & pure
    where
        applyHandler dh =
            dh ^. dropDocHandler & dhHandler %~ ($ paths) & sequenceA
lookup getClipboard event x =
    case event of
    EventChar c ->
        lookupCharGroup charGroups c <|> lookupAllCharHandler allCharHandlers c & pure
    EventKey k ->
        fromMaybe (pure Nothing) (lookupKeyMap getClipboard dict k)
    _ -> pure Nothing
    where
        EventMap dict _dropHandlers charGroups allCharHandlers = x

lookupKeyMap ::
    Applicative f => f (Maybe Clipboard) -> KeyMap a -> Events.KeyEvent ->
    Maybe (f (Maybe (DocHandler a)))
lookupKeyMap getClipboard dict (Events.KeyEvent k _scanCode keyState modKeys) =
      KeyEvent keyState modKey `Map.lookup` dict
      <&> dhHandler %~ \case
          Doesn'tWantClipboard x -> pure (Just x)
          WantsClipboard f -> getClipboard <&> (>>= f)
      <&> sequenceA
      <&> fmap sequenceA
    where
        modKey = ModKey modKeys k

lookupCharGroup :: [CharGroupHandler a] -> Char -> Maybe (DocHandler a)
lookupCharGroup charGroups char =
    charGroups ^.. Lens.traverse . cgDocHandler
    >>= dhHandler %%~ (^.. Lens.ix char)
    & listToMaybe

lookupAllCharHandler :: [AllCharsHandler a] -> Char -> Maybe (DocHandler a)
lookupAllCharHandler allCharHandlers char =
    do
        AllCharsHandler _ handler <- allCharHandlers
        (handler & dhHandler %~ ($ char) & sequenceA) ^.. Lens._Just
    & listToMaybe

charGroup :: HasCallStack => Maybe InputDoc -> Doc -> String -> (Char -> a) -> EventMap a
charGroup miDoc oDoc chars func =
    mempty
    { _emCharGroupHandlers =
        [CharGroupHandler miDoc (DocHandler oDoc callStack handler)]
    }
    where
        handler = Set.fromList chars & Map.fromSet func

-- low-level "smart constructor" in case we need to enforce
-- invariants:
charEventMap :: HasCallStack => InputDoc -> Doc -> (Char -> Maybe a) -> EventMap a
charEventMap iDoc oDoc handler =
    mempty
    { _emAllCharsHandler =
        [AllCharsHandler iDoc (DocHandler oDoc callStack handler)]
    }

allChars :: HasCallStack => InputDoc -> Doc -> (Char -> a) -> EventMap a
allChars iDoc oDoc f = withFrozenCallStack charEventMap iDoc oDoc $ Just . f

keyEventMapH :: CallStack -> KeyEvent -> Doc -> MaybeWantsClipboard a -> EventMap a
keyEventMapH tb eventType doc handler =
    mempty
    { _emKeyMap =
      Map.singleton eventType (DocHandler doc tb handler)
    }

keyEventMap :: HasCallStack => KeyEvent -> Doc -> a -> EventMap a
keyEventMap eventType doc handler =
    keyEventMapH callStack eventType doc (Doesn'tWantClipboard handler)

keysEventMap :: (HasCallStack, Monoid a, Functor f) => [MetaKey] -> Doc -> f () -> EventMap (f a)
keysEventMap keys doc act = withFrozenCallStack $ keyPresses (keys <&> toModKey) doc (mempty <$ act)

-- | Convenience method to just set the cursor
keysEventMapMovesCursor ::
    (HasCallStack, Functor f) => [MetaKey] -> Doc -> f Id -> Gui EventMap f
keysEventMapMovesCursor keys doc act = withFrozenCallStack $ keyPresses (keys <&> toModKey) doc (act <&> State.updateCursor)

keyPress :: HasCallStack => ModKey -> Doc -> a -> EventMap a
keyPress key = withFrozenCallStack keyEventMap (KeyEvent ModKey.KeyState'Pressed key)

keyPresses :: HasCallStack => [ModKey] -> Doc -> a -> EventMap a
keyPresses = withFrozenCallStack $ mconcat . map keyPress

keyPressOrRepeat :: HasCallStack => ModKey -> Doc -> a -> EventMap a
keyPressOrRepeat key doc res =
    withFrozenCallStack $
    keyEventMap (KeyEvent ModKey.KeyState'Pressed key) doc res <>
    keyEventMap (KeyEvent ModKey.KeyState'Repeating key) doc res

dropEventMap :: HasCallStack => InputDoc -> Doc -> ([FilePath] -> Maybe a) -> EventMap a
dropEventMap iDoc oDoc handler =
    mempty { _emDropHandlers = [DropHandler iDoc (DocHandler oDoc callStack handler)] }

pasteOnKey :: HasCallStack => ModKey -> Doc -> (Clipboard -> a) -> EventMap a
pasteOnKey key doc handler =
    WantsClipboard (Just . handler)
    & keyEventMapH callStack (KeyEvent ModKey.KeyState'Pressed key) doc
