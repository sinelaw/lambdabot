{-# LANGUAGE TemplateHaskell, TypeFamilies #-}
-- | GNU Talk Filters
-- needs: http://www.hyperrealm.com/main.php?s=talkfilters
-- Edward Kmett 2006

module Plugin.Filter (theModule) where

import Control.Applicative
import Plugin
import System.Directory (findExecutable)

plugin "Filter"

instance Module FilterModule where
    type ModuleState FilterModule = [(String, String, String)]
        -- ^ map from filter name to executable path
    moduleDefState _ = catMaybes <$> sequence
        [ do
            mbPath <- io (findExecutable name)
            return $! do
                path <- mbPath
                Just (name, path, descr)
        | (name, descr) <- filters
        ]
        
    moduleCmds = do
        activeFilters <- readMS
        return
            [ (command name)
                { help = say descr
                , process = \s -> do
                    case words s of
                            [] -> say ("usage: " ++ name ++ " <phrase>")
                            t -> ios80 (runFilter path (unwords t))
                }
            | (name, path, descr) <- activeFilters
            ]

filters =
    [ ("austro",     "austro <phrase>. Talk like Ahhhnold")
    , ("b1ff",       "b1ff <phrase>. B1ff of usenet yore")
    , ("brooklyn",   "brooklyn <phrase>. Yo")
    , ("chef",       "chef <phrase>. Bork bork bork")
    , ("cockney",    "cockney <phrase>. Londoner accent")
    , ("drawl",      "drawl <phrase>. Southern drawl")
    , ("dubya",      "dubya <phrase>. Presidential filter")
    , ("fudd",       "fudd <phrase>. Fudd, Elmer")
    , ("funetak",    "funetak <phrase>. Southern drawl")
    , ("jethro",     "jethro <phrase>. Now listen to a story 'bout a man named Jed...")
    , ("jive",       "jive <phrase>. Slap ma fro")
    , ("kraut",      "kraut <phrase>. German accent")
    , ("pansy",      "pansy <phrase>. Effeminate male")
    , ("pirate",     "pirate <phrase>. Talk like a pirate")
    , ("postmodern", "postmodern <phrase>. Feminazi")
    , ("redneck",    "redneck <phrase>. Deep south")
    , ("valspeak",   "valley <phrase>. Like, ya know?")
    , ("warez",      "warez <phrase>. H4x0r")
    ]

runFilter :: String -> String -> IO String
runFilter f s = do
    (out,_,_) <- popen f [] (Just s)
    return $ result out
    where result [] = "Couldn't run the filter."
          result xs = unlines . filter (not . all (==' ')) . lines $ xs
