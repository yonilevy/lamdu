{-# LANGUAGE CPP, TemplateHaskell, FlexibleContexts #-}
module Lamdu.Opts
    ( EditorOpts(..), eoWindowMode, eoJSDebugPaths, eoWindowTitle, eoSubpixelEnabled, eoEkgPort
    , Command(..), _DeleteDb, _Undo, _Editor
    , CommandWithDb(..), cCommand, cLamduDB
    , Parsed(..), _ParsedRequestVersion, _ParsedCommand
    , get
    ) where

import           Control.Applicative (optional)
import qualified Control.Lens as Lens
import           Data.List.Split (splitOn)
import           Data.Word (Word16)
import           GUI.Momentu (WindowMode(..))
import           Lamdu.Eval.JS.Types (JSDebugPaths(..))
import           Options.Applicative ((<|>))
import qualified Options.Applicative as P

import           Lamdu.Prelude

data EditorOpts = EditorOpts
    { _eoWindowMode :: WindowMode
    , _eoJSDebugPaths :: JSDebugPaths FilePath
    , _eoWindowTitle :: String
    , _eoSubpixelEnabled :: Bool
    , _eoEkgPort :: Maybe Word16
    }

data Command
    = DeleteDb
    | Undo Int
    | Import FilePath
    | Export FilePath
    | Editor EditorOpts

data CommandWithDb = CommandWithDb
    { _cCommand :: Command
    , _cLamduDB :: Maybe FilePath
    }

data Parsed = ParsedRequestVersion | ParsedCommand CommandWithDb

Lens.makeLenses ''CommandWithDb
Lens.makeLenses ''EditorOpts
Lens.makePrisms ''Parsed
Lens.makePrisms ''Command

subcommands :: P.Parser Command
subcommands =
    mconcat
    [ P.command "deletedb"
      (P.info (pure DeleteDb) (P.progDesc "Irreversibly delete the lamdu database"))
    , P.command "undo"
      (P.info
       (P.argument (Undo <$> P.auto) (P.metavar "COUNT"))
       (P.progDesc "Perform undos on the database"))
    , P.command "import"
      (P.info
       (P.argument (Import <$> P.str) (P.metavar "IMPORTPATH"))
       (P.progDesc "Import from a given JSON file path into the database"))
    , P.command "export"
      (P.info
       (P.argument (Export <$> P.str) (P.metavar "EXPORTPATH"))
       (P.progDesc "Export the database into a JSON file")
      )
    ] & P.hsubparser

jsDebugOpts :: P.Parser (JSDebugPaths FilePath)
jsDebugOpts =
    optional
    (P.option (P.eitherReader readPaths)
     (P.metavar "JSPATH[:OUTPATH[:INTERACTIVEPATH]]" <>
      P.long "jsdebug" <>
      P.help "Output the executed JS and nodejs output to files"))
    <&> fromMaybe emptyJSDebugPaths
    where
        emptyJSDebugPaths = JSDebugPaths Nothing Nothing Nothing
        readPaths str
            | length parts > 3 = Left "Too many file paths"
            | otherwise =
                Right JSDebugPaths
                { _jsDebugCodePath = parts ^? Lens.ix 0
                , _jsDebugNodeOutputPath = parts ^? Lens.ix 1
                , _jsDebugInteractivePath = parts ^? Lens.ix 2
                }
            where
                parts = splitOn ":" str

editorOpts :: P.Parser EditorOpts
editorOpts =
    EditorOpts
    <$> windowMode
    <*> jsDebugOpts
    <*> P.option P.str
        ( P.long "windowtitle"
          <> P.value "Lamdu"
          <> P.metavar "TITLE"
          <> P.showDefault
          <> P.help "Override window title"
        )
    <*> P.flag True False
        (P.long "disable-lcd-rendering"
         <> P.help "Disables LCD subpixel font rendering")
    <*> optional
        (P.option P.auto
            ( P.long "with-ekg"
            <> P.metavar "PORT"
            <> P.help
                ("Enable ekg monitoring of lamdu on given port"
#ifndef WITH_EKG
                <> " (DISABLED: Recompile with -fekg for ekg support)"
#endif
                )
            )
        )

command :: P.Parser Command
command = (Editor <$> editorOpts) <|> subcommands

windowMode :: P.Parser WindowMode
windowMode =
    P.flag' FullScreen
    ( P.long "fullscreen"
      <> P.short 'f'
      <> P.help "Run Lamdu in a fullscreen window"
    )
    <|> pure Maximized

commandWithDb :: P.Parser CommandWithDb
commandWithDb =
    CommandWithDb
    <$> command
    <*> optional
        (P.option P.str
            (P.metavar "PATH" <> P.long "lamduDB" <>
             P.help "Override path to lamdu DB"))

requestVersion :: P.Parser Parsed
requestVersion =
    P.long "version" <>
    P.help "Get the build's version information"
    & P.flag' ParsedRequestVersion

parser :: P.Parser Parsed
parser = requestVersion <|> (ParsedCommand <$> commandWithDb)

get :: IO Parsed
get =
    P.info
    (P.helper <*> parser)
    (
        P.progDesc "Lamdu - The Next Generation IDE"

{-
   Here, I use "<>" to insert a header. It goes on top of the help text
   displayed when someone types "lamdu --help".
   We're using the "Options.Applicative" module for command-line parameters and
   help text. Unfortunately, it strips out any newlines or leading space I try
   to give this header. So it doesn't print out too pretty. I tried
   chaining multiple headers with "<>", but it only keeps the last one.
 -}
     <> P.header
        ( concat
            [ "Pressing F1 while in the Lamdu environment gives help in the"
            , " lower-right of the environment's screen. This help changes"
            , " based on what's selected."
            , " For tutorials, please see the README."
            ]
        )
    )
    & P.execParser
