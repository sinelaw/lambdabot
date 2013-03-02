-- Copyright (c) 2004 Thomas Jaeger
-- Copyright (c) 2005 Simon Winwood
-- Copyright (c) 2005 Don Stewart
-- Copyright (c) 2005 David House <dmouse@gmail.com>
--
-- | Logging an IRC channel..
--
module Lambdabot.Plugin.Log (theModule) where

import Lambdabot
import Lambdabot.Plugin
import qualified Lambdabot.Message as Msg

import Control.Monad
import qualified Data.Map as M
import Data.Time
import System.Directory (createDirectoryIfMissing)
import System.FilePath
import System.IO

-- ------------------------------------------------------------------------

type Channel = Msg.Nick

type DateStamp = (Int, Int, Integer)
data ChanState = CS { chanHandle  :: Handle,
                      chanDate    :: DateStamp }
               deriving (Show, Eq)
type LogState = M.Map Channel ChanState
type Log = ModuleT LogState LB

data Event =
    Said Msg.Nick UTCTime String
    | Joined Msg.Nick String UTCTime
    | Parted Msg.Nick String UTCTime -- covers quitting as well
    | Renick Msg.Nick String UTCTime Msg.Nick
    deriving (Eq)

instance Show Event where
    show (Said nick ct what)       = timeStamp ct ++ " <" ++ Msg.nName nick ++ "> " ++ what
    show (Joined nick user ct)     = timeStamp ct ++ " " ++ show nick
                                     ++ " (" ++ user ++ ") joined."
    show (Parted nick user ct)     = timeStamp ct ++ " " ++ show nick
                                     ++ " (" ++ user ++ ") left."
    show (Renick nick user ct new) = timeStamp ct ++ " " ++ show  nick
                                     ++ " (" ++ user ++ ") is now " ++ show new ++ "."

-- * Dispatchers and Module instance declaration
--

theModule = newModule
    { moduleDefState  = return M.empty
    , moduleExit      = cleanLogState
    , moduleInit      = do
        let doLog f m hdl = logString hdl . show . f m
            wrapCB f = bindModule1 $ \msg -> do
                now <- io getCurrentTime
                -- map over the channels this message was directed to, adding to each
                -- of their log files.
                mapM_ (withValidLog (doLog f msg) now) (channels msg)
            connect signal cb = ircSignalConnect signal =<< wrapCB cb
        
        connect "PRIVMSG" msgCB
        connect "JOIN"    joinCB
        connect "PART"    partCB
        connect "NICK"    nickCB
    }

-- * Logging helpers
--

timeStamp :: UTCTime -> String
timeStamp (UTCTime _ ct) = 
    (showWidth 2 (hour `mod` 24)) ++ ":" ++
    (showWidth 2 (min  `mod` 60)) ++ ":" ++
    (showWidth 2 (sec  `mod` 60))
    where
        sec  = round ct :: Int
        min  = sec `div` 60
        hour = min `div` 60
        
-- | Show a DateStamp.
dateToString :: DateStamp -> String
dateToString (d, m, y) = (showWidth 2 $ fromInteger y) ++ "-" ++
                         (showWidth 2 $ fromEnum m + 1) ++ "-" ++
                         (showWidth 2 d)

-- | UTCTime -> DateStamp conversion
dateStamp :: UTCTime -> DateStamp
dateStamp (UTCTime day _) = (d, m, y)
    where (y,m,d) = toGregorian day

-- * State manipulation functions
--

-- | Cleans up after the module (closes files)
cleanLogState :: Log ()
cleanLogState =
    withMS $ \state writer -> do
      io $ M.fold (\cs iom -> iom >> hClose (chanHandle cs)) (return ()) state
      writer M.empty

-- | Fetch a channel from the internal map. Uses LB's fail if not found.
getChannel :: Channel -> Log ChanState
getChannel c = (readMS >>=) . mLookup $ c
    where mLookup k = maybe (fail "getChannel: not found") return . M.lookup k

getDate :: Channel -> Log DateStamp
getDate c = fmap chanDate . getChannel $ c

getHandle :: Channel -> Log Handle
getHandle c = fmap chanHandle . getChannel $ c
    -- add points. otherwise:
    -- Unbound implicit parameters (?ref::GHC.IOBase.MVar LogState, ?name::String)
    --  arising from instantiating a type signature at
    -- Plugin/Log.hs:187:30-39
    -- Probable cause: `getChannel' is applied to too few arguments

-- | Put a DateStamp and a Handle. Used by 'openChannelFile' and
--  'reopenChannelMaybe'.
putHdlAndDS :: Channel -> Handle -> DateStamp -> Log ()
putHdlAndDS c hdl ds =
        modifyMS (M.adjust (\cs -> cs {chanHandle = hdl, chanDate = ds}) c)


-- * Logging IO
--

-- | Open a file to write the log to.
openChannelFile :: Channel -> UTCTime -> Log Handle
openChannelFile chan ct =
    io $ createDirectoryIfMissing True dir >> openFile file AppendMode
    where dir  = outputDir config </> "Log" </> Msg.nTag chan </> Msg.nName chan
          date = dateStamp ct
          file = dir </> (dateToString date) <.> "txt"

-- | Close and re-open a log file, and update the state.
reopenChannelMaybe :: Channel -> UTCTime -> Log ()
reopenChannelMaybe chan ct = do
  date <- getDate chan
  when (date /= dateStamp ct) $ do
    hdl <- getHandle chan
    io $ hClose hdl
    hdl' <- openChannelFile chan ct
    putHdlAndDS chan hdl' (dateStamp ct)

-- | Initialise the channel state (if it not already inited)
initChannelMaybe :: Msg.Nick -> UTCTime -> Log ()
initChannelMaybe chan ct = do
  chanp <- liftM (M.member chan) readMS
  unless chanp $ do
    hdl <- openChannelFile chan ct
    modifyMS (M.insert chan $ CS hdl (dateStamp ct))

-- | Ensure that the log is correctly initialised etc.
withValidLog :: (Handle -> UTCTime -> Log a) -> UTCTime -> Channel -> Log a
withValidLog f ct chan = do
  initChannelMaybe chan ct
  reopenChannelMaybe chan ct
  hdl <- getHandle chan
  rv <- f hdl ct
  return rv

-- | Log a string. Main logging workhorse.
logString :: Handle -> String -> Log ()
logString hdl str = io $ hPutStrLn hdl str >> hFlush hdl
  -- We flush on each operation to ensure logs are up to date.

-- * The event loggers themselves
--

-- | When somebody joins.
joinCB :: IrcMessage -> UTCTime -> Event
joinCB msg ct = Joined (Msg.nick msg) (Msg.fullName msg) ct

-- | When somebody quits.
partCB :: IrcMessage -> UTCTime -> Event
partCB msg ct = Parted (Msg.nick msg) (Msg.fullName msg) ct

-- | When somebody changes his\/her name.
-- FIXME:  We should only do this for channels that the user is currently on.
nickCB :: IrcMessage -> UTCTime -> Event
nickCB msg ct = Renick (Msg.nick msg) (Msg.fullName msg) ct
                       (Msg.readNick msg $ drop 1 $ head $ ircMsgParams msg)

-- | When somebody speaks.
msgCB :: IrcMessage -> UTCTime -> Event
msgCB msg ct = Said (Msg.nick msg) ct
                    (tail . concat . tail $ ircMsgParams msg)
                      -- each lines is :foo
