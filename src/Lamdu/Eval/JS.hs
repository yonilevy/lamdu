{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
{-# LANGUAGE TemplateHaskell, TupleSections #-}
-- | Run a process that evaluates given compiled
module Lamdu.Eval.JS
    ( module Lamdu.Eval.JS.Types
    , Evaluator
    , Actions(..), aLoadGlobal, aReportUpdatesAvailable
    , start, stop, executeReplIOProcess
    , Dependencies(..), whilePaused
    , getResults

      -- | Export for test purposes:
    , nodeRepl
    ) where

import           Control.Applicative ((<|>))
import           Control.Concurrent.Extended (forkIO, killThread, withForkedIO)
import           Control.Concurrent.MVar
import qualified Control.Lens as Lens
import           Control.Monad (foldM, msum)
import           Control.Monad.Cont (ContT(..))
import           Control.Monad.Trans.State (State, runState)
import qualified Data.Aeson as Aeson
import           Data.Aeson.Types ((.:))
import qualified Data.Aeson.Types as Json
import qualified Data.ByteString.Extended as BS
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import           Data.IORef
import           Data.IntMap (IntMap)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.String (IsString(..))
import qualified Data.Text as Text
import           Data.Tree.Diverse (Ann(..), annotations)
import           Data.UUID.Types (UUID)
import qualified Data.UUID.Utils as UUIDUtils
import qualified Data.Vector as Vec
import           Data.Word (Word8)
import qualified Lamdu.Builtins.PrimVal as PrimVal
import           Lamdu.Calc.Identifier (Identifier(..), identHex)
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import           Lamdu.Calc.Type (Tag(..))
import           Lamdu.Data.Anchors (anonTag)
import           Lamdu.Data.Definition (Definition)
import qualified Lamdu.Data.Definition as Def
import qualified Lamdu.Eval.JS.Compiler as Compiler
import           Lamdu.Eval.JS.Types
import           Lamdu.Eval.Results (ScopeId(..), EvalResults(..))
import qualified Lamdu.Eval.Results as ER
import qualified Lamdu.Paths as Paths
import           Numeric (readHex)
import           System.Environment (getEnvironment)
import           System.FilePath (splitFileName)
import           System.IO (IOMode(..), Handle, hIsEOF, hPutStrLn, hFlush, withFile)
import           System.IO.Temp (withSystemTempFile)
import qualified System.NodeJS.Path as NodeJS
import qualified System.Process as Proc
import           System.Process.Utils (withProcess)
import           Text.Read (readMaybe)

import           Lamdu.Prelude

data Actions srcId = Actions
    { _aLoadGlobal :: V.Var -> IO (Definition (Val srcId) ())
    , _aReportUpdatesAvailable :: IO ()
    , _aJSDebugPaths :: JSDebugPaths FilePath
    }
Lens.makeLenses ''Actions

data Dependencies srcId = Dependencies
    { subExprDeps :: Set srcId
    , globalDeps :: Set V.Var
    }
instance Ord srcId => Semigroup (Dependencies srcId) where
    Dependencies x0 y0 <> Dependencies x1 y1 = Dependencies (x0 <> x1) (y0 <> y1)
instance Ord srcId => Monoid (Dependencies srcId) where
    mempty = Dependencies mempty mempty
    mappend = (<>)

data Evaluator srcId = Evaluator
    { stop :: IO ()
    , executeReplIOProcess :: IO ()
    , eDeps :: MVar (Dependencies srcId)
    , eResultsRef :: IORef (EvalResults srcId)
    }

type Parse = State (IntMap (ER.Val ()))

getNodePath :: IO FilePath
getNodePath =
    -- prefer the relative-path bin/node.exe
    Paths.getDataFileNameMaybe "bin/node.exe"
    >>= \case
    Just x -> pure x
    Nothing -> NodeJS.path

nodeRepl :: IO Proc.CreateProcess
nodeRepl =
    do
        rtsPath <- Paths.getDataFileName "js/rts.js" <&> fst . splitFileName
        nodeExePath <- getNodePath
        env <- getEnvironment
        pure (Proc.proc nodeExePath ["--interactive", "--harmony-tailcalls"])
            { Proc.std_in = Proc.CreatePipe
            , Proc.std_out = Proc.CreatePipe
            , Proc.env = Just (("NODE_PATH", rtsPath):env)
            }

parseHexBs :: Text -> ByteString
parseHexBs =
    BS.pack . map (fst . sHead . readHex . Text.unpack) . Text.chunksOf 2
    where
        sHead [] = error "parseHexBs got bad input"
        sHead (x:_) = x

parseHexNameBs :: Text -> ByteString
parseHexNameBs t =
    case Text.uncons t of
    Just ('_', n) -> parseHexBs n
    _ -> parseHexBs t

parseUUID :: Text -> UUID
parseUUID = UUIDUtils.fromSBS16 . parseHexNameBs

parseRecord :: HashMap Text Json.Value -> Parse (ER.Val ())
parseRecord obj =
    HashMap.toList obj & foldM step (Ann () ER.RRecEmpty)
    where
        step r ("cacheId", _) = pure r -- TODO: Explain/fix this
        step r (k, v) =
            parseResult v
            <&> \pv ->
            ER.RRecExtend V.RecExtend
            { V._recTag = parseHexNameBs k & Identifier & Tag
            , V._recFieldVal = pv
            , V._recRest = r
            } & Ann ()

parseWord8 :: Json.Value -> Word8
parseWord8 (Json.Number x)
    | x == fromIntegral i = i
    where
        i = truncate x
parseWord8 x = "Expected word8, given: " ++ show x & error

parseBytes :: Json.Value -> ER.Val ()
parseBytes (Json.Array vals) =
    Vec.toList vals
    <&> parseWord8
    & BS.pack & PrimVal.Bytes & PrimVal.fromKnown & ER.RPrimVal & Ann ()
parseBytes _ = error "Bytes with non-array data"

parseInject :: Text -> Maybe Json.Value -> Parse (ER.Val ())
parseInject tag mData =
    case mData of
    Nothing -> Ann () ER.RRecEmpty & pure
    Just v -> parseResult v
    <&> \iv ->
    ER.RInject V.Inject
    { V._injectTag = parseHexNameBs tag & Identifier & Tag
    , V._injectVal = iv
    } & Ann ()

(.?) :: Monad m => Json.FromJSON a => Json.Object -> Text -> m a
obj .? tag = Json.parseEither (.: tag) obj & either fail pure

parseObj :: Json.Object -> Parse (ER.Val ())
parseObj obj =
    msum
    [ obj .? "array"
      <&> \(Json.Array arr) ->
            Vec.toList arr & Lens.traversed %%~ parseResult <&> ER.RArray <&> Ann ()
    , obj .? "bytes" <&> parseBytes <&> pure
    , obj .? "number" <&> read <&> fromDouble <&> pure
    , obj .? "tag" <&> (`parseInject` (obj .? "data"))
    , obj .? "func" <&> (\(Json.Number x) -> round x & ER.RFunc & Ann () & pure)
    ] & fromMaybe (parseRecord obj)

parseResult :: Json.Value -> Parse (ER.Val ())
parseResult (Json.Number x) = realToFrac x & fromDouble & pure
parseResult (Json.Object obj) =
    case obj .? "cachedVal" of
    Just cacheId -> Lens.use (Lens.singular (Lens.ix cacheId))
    Nothing ->
        do
            x <- parseObj obj
            case obj .? "cacheId" <|> obj .? "func" of
                Nothing -> pure ()
                Just cacheId -> Lens.at cacheId ?= x
            pure x
parseResult x = "Unsupported encoded JS output: " ++ show x & fail

fromDouble :: Double -> ER.Val ()
fromDouble = Ann () . ER.RPrimVal . PrimVal.fromKnown . PrimVal.Float

addVal ::
    Ord srcId =>
    (UUID -> srcId) -> Json.Object ->
    Parse
    ( Map srcId (Map ScopeId (ER.Val ())) ->
      Map srcId (Map ScopeId (ER.Val ()))
    )
addVal fromUUID obj =
    case obj .? "result" of
    Nothing -> pure id
    Just result ->
        parseResult result
        <&> \pr ->
        Map.alter
        (<> Just (Map.singleton (ScopeId scope) pr))
        (fromUUID (parseUUID exprId))
    where
        Just scope = obj .? "scope"
        Just exprId = obj .? "exprId"

newScope ::
    Ord srcId =>
    (UUID -> srcId) -> Json.Object ->
    Parse
    ( Map srcId (Map ScopeId [(ScopeId, ER.Val ())]) ->
      Map srcId (Map ScopeId [(ScopeId, ER.Val ())])
    )
newScope fromUUID obj =
    do
        arg <-
            case obj .? "arg" of
            Nothing -> fail "Scope report missing arg"
            Just x -> parseResult x
        let apply = Map.singleton (ScopeId parentScope) [(ScopeId scope, arg)]
        let addApply Nothing = Just apply
            addApply (Just x) = Just (Map.unionWith (++) x apply)
        Map.alter addApply (fromUUID (parseUUID lamId)) & pure
    where
        Just parentScope = obj .? "parentScope"
        Just scope = obj .? "scope"
        Just lamId = obj .? "lamId"

completionSuccess :: Json.Object -> Parse (ER.Val ())
completionSuccess obj =
    case obj .? "result" of
    Nothing -> fail "Completion success report missing result"
    Just x -> parseResult x

completionError ::
    Monad m => (UUID -> srcId) -> Json.Object -> m (ER.EvalException srcId)
completionError fromUUID obj =
    case obj .? "err" of
    Nothing -> "Completion error report missing valid err: " ++ show obj & fail
    Just x ->
        ER.EvalException
        <$> do
                errTypeStr <- x .? "error"
                readMaybe errTypeStr & toEither "invalid error type"
        <*> x .? "desc"
        <*> (
            case (,) <$> (x .? "globalId") <*> (x .? "exprId") of
            Nothing -> pure Nothing
            Just (g, e) ->
                (,)
                <$> ER.decodeWhichGlobal g
                ?? fromUUID (parseUUID e)
                <&> Just
        )
        & either fail pure
    where
        toEither msg = maybe (Left msg) Right

processEvent ::
    Ord srcId =>
    (UUID -> srcId) -> IORef (EvalResults srcId) -> Actions srcId ->
    Json.Object -> IO ()
processEvent fromUUID resultsRef actions obj =
    case event of
    "Result" ->
        runParse (addVal fromUUID obj) (ER.erExprValues %~)
    "NewScope" ->
        runParse (newScope fromUUID obj) (ER.erAppliesOfLam %~)
    "CompletionSuccess" ->
        runParse (completionSuccess obj) (\res -> ER.erCompleted ?~ Right res)
    "CompletionError" ->
        runParse (completionError fromUUID obj) (\exc -> ER.erCompleted ?~ Left exc)
    _ -> "Unknown event " ++ event & putStrLn
    where
        runParse act postProcess =
            do
                atomicModifyIORef' resultsRef $
                    \oldEvalResults ->
                    let (res, newCache) = runState act (oldEvalResults ^. ER.erCache)
                    in  oldEvalResults
                        & ER.erCache .~ newCache
                        & postProcess res
                        & (, ())
                actions ^. aReportUpdatesAvailable
        Just event = obj .? "event"

withJSDebugHandles :: Traversable t => t FilePath -> (t Handle -> IO a) -> IO a
withJSDebugHandles paths =
    traverse withPath paths & runContT
    where
        withPath path = withFile path WriteMode & ContT

compilerActions ::
    Ord a =>
    (a -> UUID) -> MVar (Dependencies a) -> Actions a -> (String -> IO ()) ->
    Compiler.Actions IO
compilerActions toUUID depsMVar actions output =
    Compiler.Actions
    { Compiler.readAssocName = pure . fromString . identHex . tagName
    , Compiler.readAssocTag = pure anonTag & const
    , Compiler.readGlobal =
        readGlobal $
        \def ->
        ( Dependencies
          { subExprDeps = def ^.. Def.defBody . Lens.folded . annotations & Set.fromList
          , globalDeps = mempty
          }
        , def & Def.defBody . Lens.mapped . annotations %~ Compiler.ValId . toUUID
        )
    , Compiler.readGlobalType = readGlobal ((^. Def.defType) <&> (,) mempty)
    , Compiler.output = output
    , Compiler.loggingMode = Compiler.loggingEnabled
    }
    where
        readGlobal f globalId =
            modifyMVar depsMVar $ \oldDeps ->
            globalId & actions ^. aLoadGlobal
            <&> f
            <&> _1 %~ \deps ->
            -- This happens inside the modifyMVar so
            -- loads are under "lock" and not racy
            oldDeps <> deps <>
            Dependencies
            { subExprDeps = mempty
            , globalDeps = Set.singleton globalId
            }

stripInteractive :: ByteString -> ByteString
stripInteractive line
    | "> " `BS.isPrefixOf` line = stripInteractive (BS.drop 2 line)
    | otherwise = BS.dropWhile (`elem` irrelevant) line
    where
        irrelevant = BS.unpack ". "

processNodeOutput :: Maybe Handle -> (Json.Object -> IO ()) -> Handle -> IO ()
processNodeOutput copyNodeOutput handleEvent stdout =
    do
        isEof <- hIsEOF stdout
        when isEof $ fail "EOF"
        rawLine <- BS.hGetLine stdout
        traverse_ (flushedLine rawLine) copyNodeOutput
        let line = stripInteractive rawLine
        case Aeson.decode (BS.lazify line) of
            Nothing
                | line `elem` ["'use strict'", "undefined", ""] -> pure ()
                | otherwise -> "Failed to decode: " ++ show line & fail
            Just obj -> handleEvent obj
    & forever
    where
        flushedLine line handle =
            do
                BS.hPutStr handle line
                BS.hPutStr handle "\n"
                hFlush handle

asyncStart ::
    Ord srcId =>
    (srcId -> UUID) -> (UUID -> srcId) ->
    MVar (Dependencies srcId) -> MVar () -> IORef (EvalResults srcId) ->
    Def.Expr (Val srcId) -> Actions srcId ->
    IO ()
asyncStart toUUID fromUUID depsMVar executeReplMVar resultsRef replVal actions =
    withSystemTempFile "lamdu-output.js" $
    \lamduOutputPath lamduOutputHandle ->
    do
        procParams <- nodeRepl
        withProcess procParams $
            \(Just stdin, Just stdout, Nothing, _handle) ->
            withJSDebugHandles (actions ^. aJSDebugPaths) $ \jsHandles ->
            do
                let handlesJS = lamduOutputHandle : jsHandles ^.. jsDebugCodePath . Lens._Just
                let outputJS line = traverse_ (`hPutStrLn` line) handlesJS
                let flushJS = traverse_ hFlush handlesJS
                let handleEvent = processEvent fromUUID resultsRef actions
                let nodeOutputHandle = jsHandles ^. jsDebugNodeOutputPath
                let processOutput = processNodeOutput nodeOutputHandle handleEvent stdout
                withForkedIO processOutput $
                    do
                        replVal <&> annotations %~ Compiler.ValId . toUUID
                            & Compiler.compileRepl
                                (compilerActions toUUID depsMVar actions outputJS)
                        flushJS
                        let flushedOutput handle msg =
                                do
                                    hPutStrLn handle msg
                                    hFlush handle
                        let outputInteractive msg =
                                do
                                    flushedOutput stdin msg
                                    traverse_ (`flushedOutput` msg)
                                        (jsHandles ^. jsDebugInteractivePath)
                        "'use strict';\n" ++
                            "var repl = require(" ++ show lamduOutputPath ++ ");"
                            & outputInteractive
                        do
                            takeMVar executeReplMVar
                            outputInteractive "repl(x => undefined);"
                            & forever

-- | Pause the evaluator, yielding all dependencies of evaluation so
-- far. If any dependency changed, this evaluation is stale.
--
-- Pause must be called for a started/resumed evaluator, and if given
-- an already paused evaluator, will wait for its resumption.
whilePaused :: Evaluator srcId -> (Dependencies srcId -> IO a) -> IO a
whilePaused = withMVar . eDeps

start ::
    Ord srcId => (srcId -> UUID) -> (UUID -> srcId) ->
    Actions srcId -> Def.Expr (Val srcId) -> IO (Evaluator srcId)
start toUUID fromUUID actions replExpr =
    do
        depsMVar <-
            newMVar Dependencies
            { globalDeps = Set.empty
            , subExprDeps = replExpr ^.. Lens.folded . annotations & Set.fromList
            }
        resultsRef <- newIORef ER.empty
        executeReplMVar <- newEmptyMVar
        tid <- asyncStart toUUID fromUUID depsMVar executeReplMVar resultsRef replExpr actions & forkIO
        pure Evaluator
            { stop = killThread tid
            , executeReplIOProcess = putMVar executeReplMVar ()
            , eDeps = depsMVar
            , eResultsRef = resultsRef
            }

getResults :: Evaluator srcId -> IO (EvalResults srcId)
getResults = readIORef . eResultsRef
