--
-- | Support for quotes
--
module Plugin.Slap (theModule) where

import Plugin
import qualified Message (nick, showNick)

PLUGIN Quote

instance Module QuoteModule () where
    moduleCmds _           = ["slap"]
    moduleHelp _ _         = "slap <nick>. Slap someone amusingly."
    process _ msg _ _ rest = ios $ slapRandom (if rest == "me" then sender else rest)
       where sender = Message.showNick msg $ Message.nick msg

------------------------------------------------------------------------

-- | Return a random arr-quote
slapRandom :: String -> IO String
slapRandom = (randomElem slapList `ap`) . return

slapList :: [String -> String]
slapList =
    [("/me slaps " ++)
    ,(\x -> "/me smacks " ++ x ++ " about with a large trout")
    ,("/me beats up " ++)
    ,("why on earth would I slap " ++)
    ]
