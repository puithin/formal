{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE FlexibleContexts #-}


module Main where

import Text.InterpolatedString.Perl6

import Control.Applicative
import Control.Monad.State hiding (lift)

import System.IO
import System.Environment
import System.Exit
import System.Console.ANSI

import Network.HTTP
import Network.URI

import Text.Pandoc

import Data.Char (ord, isAscii)
import Data.List as L
import Data.String.Utils
import Data.URLEncoded

import Formal.Parser
import Formal.Javascript
import Formal.TypeCheck hiding (split)
import qualified Data.ByteString.Char8 as B

import Data.FileEmbed
import System.Process

-- Main
-- ----

toEntities :: String -> String
toEntities [] = ""
toEntities (c:cs) | isAscii c = c : toEntities cs
                  | otherwise = [qq|&#{ord c};{toEntities cs}|]

toHTML :: String -> String
toHTML = toEntities . writeHtmlString defaultWriterOptions . readMarkdown defaultParserState

monitor :: String -> IO (Either [String] a) -> IO a
monitor x d = do putStr$ "[ ] " ++ x
                 hFlush stdout
                 d' <- d
                 case d' of
                   Right y -> do putStr "\r["
                                 setSGR [SetColor Foreground Dull Green]
                                 putStr "*"
                                 setSGR []
                                 putStrLn$ "] " ++ x
                                 return y
                   Left y  -> do putStr "\r["
                                 setSGR [SetColor Foreground Dull Red]
                                 putStr "X"
                                 setSGR []
                                 putStrLn$ "] " ++ x
                                 putStrLn ""
                                 mapM putStrLn y
                                 exitFailure

main :: IO ()
main  = do rc <- parseArgs <$> getArgs
           hFile  <- openFile (head $ inputs rc) ReadMode
           src <- (\ x -> x ++ "\n") <$> hGetContents hFile
   
           src' <- monitor "Parsing" . return$
                   case parseFormal src of
                     Left ex -> Left [show ex]
                     Right x -> Right x
   
           as <- monitor "Type Checking" . return $
                   case tiProgram src' of
                     (as, []) -> Right as
                     (_, y)  -> Left y
   
           (js, tests) <- monitor "Generating Javascript"$
                   do let tests = case src' of (Program xs) -> get_tests xs
                      let html = highlight tests $ toHTML (annotate_tests src src')
                      writeFile ((output rc) ++ ".html") (B.unpack header ++ html ++ B.unpack footer)
                      let js = compress $ render src'
                      return$ Right (js, render_spec src')
   
           js <- if optimize rc then (monitor "Optimizing"$ closure js) else return js
   
           writeFile (output rc ++ ".js") js
           writeFile (output rc ++ ".spec.js") tests
           writeFile (output rc ++ ".node.js") 
                         (B.unpack jasmine ++ "\n" ++ js ++ "\n" ++ tests ++ "\n" ++ B.unpack console)
           z <- system$  "node " ++ output rc ++ ".node.js"
           case z of 
             ExitFailure _ -> return ()
             ExitSuccess -> if (show_types rc) 
                            then putStrLn$ "\nTypes\n\n  " ++ concat (map f as)
                            else return ()

    where f (x, y) = show x ++ "\n    " ++ concat (L.intersperse "\n    " (map show y)) ++ "\n\n  "

closure :: String -> IO (Either a String)
closure x = do let uri = case parseURI "http://closure-compiler.appspot.com/compile" of Just x -> x

                   y = export$ importList [ ("output_format", "text")
                                          , ("output_info", "compiled_code")
                                          , ("compilation_level", "ADVANCED_OPTIMIZATIONS")
                                          , ("js_code", x) ]

                   args = [ mkHeader HdrContentLength (show$ length y)
                          , mkHeader HdrContentType "application/x-www-form-urlencoded" ]

               rsp <- simpleHTTP (Request uri POST args y)
               txt <- getResponseBody rsp

               return$ Right txt
                                         
data RunConfig = RunConfig { inputs :: [String]
                           , output :: String
                           , show_types :: Bool
                           , optimize :: Bool
                           , run_tests :: Bool 
                           , write_docs :: Bool }

parseArgs :: [String] -> RunConfig
parseArgs = fst . runState argsParser

  where argsParser = do args <- get
                        case args of
                          []     -> return $ RunConfig [] "default" False True True True
                          (x:xs) -> do put xs
                                       case x of
                                         "-t"    -> do x <- argsParser
                                                       return $ x { show_types = True }
                                         "-no-opt" -> do x <- argsParser
                                                         return $ x { optimize = False }
                                         "-o"    -> do (name:ys) <- get
                                                       put ys
                                                       RunConfig a _ c d e f <- argsParser
                                                       return $ RunConfig (x:a) name c d e f
                                         ('-':_) -> error "Could not parse options"
                                         z       -> do RunConfig a _ c d e f<- argsParser
                                                       let b = last $ split "/" $ head $ split "." z
                                                       return $ RunConfig (x:a) b c d e f

header  = $(embedFile "header.html")
footer  = $(embedFile "footer.html")
jasmine = $(embedFile "lib/js/jasmine-1.0.1/jasmine.js")
console = $(embedFile "lib/js/console.js")
