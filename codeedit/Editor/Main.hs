{-# LANGUAGE OverloadedStrings, Rank2Types#-}
module Main(main) where

import Control.Arrow (second)
import Control.Monad (liftM, unless, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer (WriterT, runWriterT)
import Data.ByteString (unpack)
import Data.IORef
import Data.List(intercalate)
import Data.MRUMemo (memo, memoIO)
import Data.Monoid(Last(..), Monoid(..))
import Data.Store.Transaction (Transaction)
import Data.Vector.Vector2(Vector2)
import Data.Word(Word8)
import Editor.Anchors (DBTag)
import Editor.OTransaction (runOTransaction)
import Graphics.DrawingCombinators((%%))
import Graphics.UI.Bottle.Animation(AnimId)
import Graphics.UI.Bottle.MainLoop(mainLoopWidget)
import Graphics.UI.Bottle.Widget(Widget)
import Numeric (showHex)
import System.FilePath ((</>))
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.Map as Map
import qualified Data.Store.Db as Db
import qualified Data.Store.Transaction as Transaction
import qualified Data.Vector.Vector2 as Vector2
import qualified Editor.Anchors as Anchors
import qualified Editor.BranchGUI as BranchGUI
import qualified Editor.CodeEdit as CodeEdit
import qualified Editor.Config as Config
import qualified Editor.ExampleDB as ExampleDB
import qualified Editor.ITransaction as IT
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.DrawingCombinators.Utils as DrawUtils
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.Rect as Rect
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.EventMapDoc as EventMapDoc
import qualified Graphics.UI.Bottle.Widgets.FlyNav as FlyNav
import qualified Graphics.UI.Bottle.Widgets.TextEdit as TextEdit
import qualified System.Directory as Directory
import qualified System.Info

defaultFont :: String -> FilePath
defaultFont "darwin" = "/Library/Fonts/Arial.ttf"
defaultFont _ = "/usr/share/fonts/truetype/freefont/FreeSerifBold.ttf"

main :: IO ()
main = do
  home <- Directory.getHomeDirectory
  let bottleDir = home </> "bottle"
  Directory.createDirectoryIfMissing False bottleDir
  font <- Draw.openFont (defaultFont System.Info.os)
  Db.withDb (bottleDir </> "codeedit.db") $ runDbStore font . Anchors.dbStore

rjust :: Int -> a -> [a] -> [a]
rjust len x xs = replicate (length xs - len) x ++ xs

encodeHex :: [Word8] -> String
encodeHex = concatMap (rjust 2 '0' . (`showHex` ""))

drawAnimId :: Draw.Font -> AnimId -> DrawUtils.Image
drawAnimId font = DrawUtils.drawText font . intercalate "." . map (encodeHex . take 2 . unpack)

annotationSize :: Vector2 Draw.R
annotationSize = 5

addAnnotations :: Draw.Font -> Anim.Frame -> Anim.Frame
addAnnotations font = Anim.atFSubImages $ Map.mapWithKey annotateItem
  where
    annotateItem animId = map . second $ annotatePosImage animId
    annotatePosImage animId posImage =
      (`Anim.atPiImage` posImage) . mappend .
      (Vector2.uncurry Draw.scale antiScale %%) .
      (Draw.translate (0, -1) %%) $
      drawAnimId font animId
      where
        -- Cancel out on the scaling done in Anim so
        -- that our annotation is always the same size
        antiScale = annotationSize / fmap (max 1) (Rect.rectSize (Anim.piRect posImage))

whenApply :: Bool -> (a -> a) -> a -> a
whenApply False _ = id
whenApply True f = f

mainLoopDebugMode :: Draw.Font -> IO (Widget IO) -> (Widget IO -> IO (Widget IO)) -> IO a
mainLoopDebugMode font makeWidget addHelp = do
  debugModeRef <- newIORef False
  let
    getAnimHalfLife = do
      isDebugMode <- readIORef debugModeRef
      return $ if isDebugMode then 1.0 else 0.05
    addDebugMode widget = do
      isDebugMode <- readIORef debugModeRef
      let
        doc = (if isDebugMode then "Disable" else "Enable") ++ " Debug Mode"
        set = writeIORef debugModeRef (not isDebugMode)
      return .
        whenApply isDebugMode (Widget.atFrame (addAnnotations font)) $
        Widget.strongerEvents
        (Widget.keysEventMap Config.debugModeKeys doc set)
        widget
    makeDebugModeWidget = addHelp =<< addDebugMode =<< makeWidget
  mainLoopWidget makeDebugModeWidget getAnimHalfLife

makeFlyNav :: IO (Widget IO -> IO (Widget IO))
makeFlyNav = do
  flyNavState <- newIORef FlyNav.initState
  return $ \widget -> do
    fnState <- readIORef flyNavState
    return .
      FlyNav.make WidgetIds.flyNav
      fnState (writeIORef flyNavState) $
      widget

-- Safely make an IORef whose initial value needs to refer to the same
-- IORef (for writes)
fixIORef :: ((a -> IO ()) -> IO a) -> IO (IORef a)
fixIORef mkInitial = do
  var <- newIORef undefined
  writeIORef var =<< mkInitial (writeIORef var)
  return var

runDbStore :: Draw.Font -> Transaction.Store DBTag IO -> IO a
runDbStore font store = do
  ExampleDB.initDB store
  flyNavMake <- makeFlyNav
  addHelp <-
    EventMapDoc.makeToggledHelpAdder Config.overlayDocKeys
    (Config.helpStyle font)
  let
    updateCacheWith _             (Last Nothing) = return ()
    updateCacheWith writeNewCache (Last (Just newCache)) =
      writeNewCache newCache

    newMemoFromCache writeMemo sugarCache =
      memoIO .
      (fmap . liftM . Widget.atMkSizeDependentWidgetData) memo $
      mkWidgetWithFallback (Config.baseStyle font) dbToIO
      (updateCacheWith writeNewCache) sugarCache
      where
        writeNewCache = writeMemo <=< newMemoFromCache writeMemo

  initSugarCache <- dbToIO $ viewToDb CodeEdit.makeSugarCache
  memoRef <- fixIORef $ \writeMemo -> newMemoFromCache writeMemo initSugarCache

  let
    -- TODO: Move this logic to some more common place?
    makeWidget = do
      mkWidget <- readIORef memoRef
      flyNavMake =<< mkWidget =<< dbToIO (Anchors.getP Anchors.cursor)

  mainLoopDebugMode font makeWidget addHelp
  where
    dbToIO = Transaction.run store
    viewToDb act = do
      view <- Anchors.getP Anchors.view
      Transaction.run (Anchors.viewStore view) act

type SugarCache = CodeEdit.SugarCache (Transaction DBTag IO)

mkWidgetWithFallback
  :: TextEdit.Style
  -> (forall a. Transaction DBTag IO a -> IO a)
  -> (Last SugarCache -> IO ())
  -> SugarCache
  -> Widget.Id
  -> IO (Widget IO)
mkWidgetWithFallback style dbToIO updateCache sugarCache cursor = do
  (isValid, widget) <-
    dbToIO $ do
      candidateWidget <- fromCursor cursor
      (isValid, widget) <-
        if Widget.isFocused candidateWidget
        then return (True, candidateWidget)
        else do
          finalWidget <- fromCursor rootCursor
          Anchors.setP Anchors.cursor rootCursor
          return (False, finalWidget)
      unless (Widget.isFocused widget) $
        fail "Root cursor did not match"
      return (isValid, widget)
  unless isValid . putStrLn $ "Invalid cursor: " ++ show cursor
  return $ Widget.atEvents (saveCache <=< runWriterT) widget
  where
    fromCursor = makeRootWidget style dbToIO sugarCache
    saveCache (eventResult, mCacheCache) = do
      ~() <- updateCache mCacheCache
      return eventResult
    rootCursor = WidgetIds.fromIRef Anchors.panesIRef

makeRootWidget
  :: TextEdit.Style
  -> (forall a. Transaction DBTag IO a -> IO a)
  -> SugarCache
  -> Widget.Id
  -> Transaction DBTag IO (Widget (WriterT (Last SugarCache) IO))
makeRootWidget style dbToIO cache cursor =
  -- Get rid of OTransaction/ITransaction wrappings
  liftM
    (Widget.atEvents
     (Writer.mapWriterT (dbToIO . IT.runITransaction) .
      (lift . attachCursor =<<))) .
    runOTransaction cursor style $
    makeCodeEdit cache
  where
    attachCursor eventResult = do
      maybe (return ()) (IT.transaction . Anchors.setP Anchors.cursor) $
        Widget.eCursor eventResult
      return eventResult
    makeCodeEdit =
      BranchGUI.makeRootWidget CodeEdit.makeSugarCache .
      CodeEdit.makeCodeEdit
