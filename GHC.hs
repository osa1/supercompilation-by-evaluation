{-# LANGUAGE ViewPatterns #-}
module GHC where

import Core.Syntax

import Utilities
import StaticFlags

import Control.Exception

import System.Directory
import System.Exit
import System.IO
import System.Process


termToHaskell :: Term -> String
termToHaskell = show . pPrintPrec haskellLevel 0

termToHaskellBinding :: String -> Term -> [String]
termToHaskellBinding name e = (name ++ " = " ++ l) : map (replicate indent ' ' ++) ls
  where indent = length name + 3
        (l:ls) = lines $ termToHaskell e

languageLine :: String
languageLine = "{-# LANGUAGE ExtendedDefaultRules, NoMonoPatBinds #-}"

testingModule :: String -> Term -> Term -> String
testingModule wrapper e test_e = unlines $
    languageLine :
    "module Main(main) where" :
    "import Control.DeepSeq" :
    "import Data.Time.Clock.POSIX (getPOSIXTime)" :
    [wrapper] ++
    "" :
    "time_ :: IO a -> IO Double" :
    "time_ act = do { start <- getTime; act; end <- getTime; return $! (Prelude.-) end start }" :
    "" :
    "getTime :: IO Double" :
    "getTime = (fromRational . toRational) `fmap` getPOSIXTime" :
    "" :
    "main = do { t <- time_ (rnf results `seq` return ()); print t }" :
    "  where results = map assertEq tests" :
    "" :
    "assertEq :: (Show a, Eq a) => (a, a) -> ()" :
    "assertEq (x, y) = if x == y then () else error (\"FAIL! \" ++ show x ++ \", \" ++ show y)" :
    "" :
    termToHaskellBinding "root" e ++
    termToHaskellBinding "tests" test_e

printingModule :: String -> Term -> String
printingModule wrapper e = unlines $
    languageLine :
    "module Main(main, root) where" :
    "import Text.Show.Functions" :
    [wrapper] ++
    "" :
    "main = print root" :
    "" :
    termToHaskellBinding "root" e



ghcVersion :: IO [Int]
ghcVersion = do
    (ExitSuccess, compile_out, "") <- readProcessWithExitCode "ghc" ["--version"] ""
    return $ map read . seperate '.' . last . words $ compile_out

typechecks :: String -> Term -> IO Bool
typechecks wrapper term = do
    (ec, _out, err) <- withTempFile "Main.hs" $ \(file, h) -> do
        hPutStr h haskell
        hClose h
        readProcessWithExitCode "ghc" ["-c", file, "-fforce-recomp"] ""
    case ec of
      ExitSuccess -> return True
      _ -> do
        putStrLn err
        return False
  where
    haskell = printingModule wrapper term

normalise :: String -> Term -> IO (Either String String)
normalise wrapper term = do
    let haskell = printingModule wrapper term
    (ec, out, err) <- withTempFile "Main.hs" $ \(file, h) -> do
        hPutStr h haskell
        hClose h
        readProcessWithExitCode "ghc" ["--make", "-O2", file, "-ddump-simpl", "-fforce-recomp"] ""
    case ec of
      ExitSuccess   -> return (Right out)
      ExitFailure _ -> putStrLn haskell >> return (Left err)

runCompiled :: String -> Term -> Term -> IO (String, Either String (Bytes, Seconds, Bytes, Seconds))
runCompiled wrapper e test_e = withTempFile "Main" $ \(exe_file, exe_h) -> do
    hClose exe_h
    let haskell = testingModule wrapper e test_e
    (compile_t, (ec, compile_out, compile_err)) <- withTempFile "Main.hs" $ \(hs_file, hs_h) -> do
        hPutStr hs_h haskell
        hClose hs_h
        ghc_ver <- ghcVersion
        time $ readProcessWithExitCode "ghc" (["--make", "-O2", hs_file, "-fforce-recomp", "-o", exe_file] ++ ["-ddump-simpl" | not qUIET] ++ ["-rtsopts" | ghc_ver >= [7]]) ""
    compiled_size <- fileSize exe_file
    case ec of
      ExitFailure _ -> putStrLn haskell >> return (haskell, Left compile_err)
      ExitSuccess   -> do
          (ec, run_out, run_err) <- readProcessWithExitCode exe_file ["+RTS", "-t"] ""
          case ec of
            ExitFailure _ -> putStrLn haskell >> return (haskell, Left (unlines [compile_out, run_err]))
            ExitSuccess -> do
              -- <<ghc: 7989172 bytes, 16 GCs, 20876/20876 avg/max bytes residency (1 samples), 1M in use, 0.00 INIT (0.00 elapsed), 0.02 MUT (0.51 elapsed), 0.00 GC (0.00 elapsed) :ghc>>
              let [t_str] = lines run_out
                  [gc_stats] = (filter ("<<ghc" `isPrefixOf`) . lines) run_err
                  total_bytes_allocated = read (words gc_stats !! 1)
              return (haskell, Right (compiled_size, compile_t, total_bytes_allocated, read t_str))

withTempFile :: String -> ((FilePath, Handle) -> IO b) -> IO b
withTempFile name action = do
    tmpdir <- getTemporaryDirectory
    bracket
        (openTempFile tmpdir name)
        (\(fp,h) -> hClose h >> removeFile fp)
        action
