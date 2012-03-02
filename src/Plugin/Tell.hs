{-# LANGUAGE TemplateHaskell, TypeFamilies #-}
{- Leave a message with lambdabot, the faithful secretary

> 17:11 < davidhouse> @tell dmhouse foo
> 17:11 < hsbot> Consider it noted
> 17:11 < davidhouse> @tell dmhouse bar
> 17:11 < hsbot> Consider it noted
> 17:11 < dmhouse> hello!
> 17:11 < hsbot> dmhouse: You have 2 new messages. '/msg hsbot @messages' to read them.
> 17:11 < dmhouse> Notice how I'm speaking again, and hsbot isn't buzzing me more than that one time.
> 17:12 < dmhouse> It'll buzz me after a day's worth of not checking my messages.
> 17:12 < dmhouse> If I want to check them in the intermittent period, I can either send a /msg, or:
> 17:12 < dmhouse> @messages?
> 17:12 < hsbot> You have 2 messages
> 17:12 < dmhouse> Let's check them, shall we?
>
> [In a /msg to hsbot]
> 17:12 <hsbot> davidhouse said less than a minute ago: foo
> 17:12 <hsbot> davidhouse said less than a minute ago: bar
>
> [Back in the channel
> 17:12 < dmhouse> You needn't use a /msg, however. If you're not going to annoy the channel by printing 20 of
>                  your messages, feel free to just type '@messages' in the channel.
> 17:12 < davidhouse> @tell dmhouse foobar
> 17:12 < hsbot> Consider it noted
> 17:12 < davidhouse> @ask dmhouse barfoo
> 17:12 < hsbot> Consider it noted
> 17:12 < davidhouse> You can see there @ask. It's just a synonym for @tell, but it prints "foo asked X ago M",
>                     which is more natural. E.g. '@ask dons whether he's applied my latest patch yet?'
> 17:13 < dmhouse> For the admins, a useful little debugging tool is @print-notices.
> 17:13 < hsbot> dmhouse: You have 2 new messages. '/msg hsbot @messages' to read them.
> 17:14 < dmhouse> Notice that hsbot pinged me there, even though it's less than a day since I last checked my
>                  messages, because there have been some new ones posted.
> 17:14 < dmhouse> @print-notices
> 17:14 < hsbot> {"dmhouse":=(Just Thu Jun  8 17:13:46 BST 2006,[Note {noteSender = "davidhouse", noteContents =
>                "foobar", noteTime = Thu Jun  8 17:12:50 BST 2006, noteType = Tell},Note {noteSender =
                 "davidhouse", noteContents = "barfoo", noteTime = Thu Jun  8 17:12:55 BST 2006, noteType = Ask}])}
> 17:15 < dmhouse> There you can see the two notes. The internal state is a map from recipient nicks to a pair of
>                  (when we last buzzed them about having messages, a list of the notes they've got stacked up).
> 17:16 < dmhouse> Finally, if you don't want to bother checking your messages, then the following command will
>                  likely be useful.
> 17:16 < dmhouse> @clear-messages
> 17:16 < hsbot> Messages cleared.
> 17:16 < dmhouse> That's all, folks!
> 17:17 < dmhouse> Any comments, queries or complaints to dmhouse@gmail.com. The source should be fairly readable, so
>                  hack away!
-}

module Plugin.Tell where

import Control.Arrow (first)
import qualified Data.Map as M
import Text.Printf (printf)

import Lambdabot.AltTime
import Lambdabot.Message (Message, Nick, nick, lambdabotName)
import qualified Lambdabot.Message as Msg
import Plugin

-- | Was it @tell or @ask that was the original command?
data NoteType    = Tell | Ask deriving (Show, Eq, Read)
-- | The Note datatype. Fields self-explanatory.
data Note        = Note { noteSender   :: Nick,
                          noteContents :: String,
                          noteTime     :: ClockTime,
                          noteType     :: NoteType }
                   deriving (Eq, Show, Read)
-- | The state. A map of (times we last told this nick they've got messages, the
--   messages themselves)
type NoticeBoard = M.Map Nick (Maybe ClockTime, [Note])
-- | A nicer synonym for the Tell monad.

plugin "Tell"

instance Module TellModule where
    type ModuleState TellModule = NoticeBoard
    
    moduleCmds _ =
        [ (command "tell")
            { help = say "tell <nick> <message>. When <nick> shows activity, tell them <message>."
            , process = \args -> withMsg $ \msg ->
                lift (doTell args msg Tell) >>= mapM_ say
            }
        , (command "ask")
            { help = say "ask <nick> <message>. When <nick> shows activity, ask them <message>."
            , process = \args -> withMsg $ \msg ->
                lift (doTell args msg Ask) >>= mapM_ say
            }
        , (command "messages")
            { help = say "messages. Check your messages."
            , process = \args -> withMsg $ \msg ->
                lift (doMessages msg False) >>= mapM_ say
            }
        , (command "messages-loud")
            { help = say "messages. Check your messages."
            , process = \args -> withMsg $ \msg ->
                lift (doMessages msg True) >>= mapM_ say
            }
        , (command "messages?")
            { help = say "messages?. Tells you whether you have any messages"
            , process = const $ withMsg $ \msg -> do
                  sender <- getSender
                  ms <- lift (getMessages msg sender)
                  case ms of
                    Just _ -> lift (doRemind msg sender) >>= mapM_ say
                    Nothing   -> say "Sorry, no messages today."
            }
        , (command "clear-messages")
            { help = say "clear-messages. Clears your messages."
            , process = const $ do
                sender <- getSender
                lift (clearMessages sender)
                say "Messages cleared."
            }
        , (command "print-notices")
            { privileged = True
            , help = say "print-notices. Print the current map of notes."
            , process = const ((say . show) =<< lift readMS)
            }
        , (command "purge-notices")
            { privileged = True
            , help = say $
                "purge-notices [<nick> [<nick> [<nick> ...]]]]. "
                ++ "Clear all notes for specified nicks, or all notices if you don't "
                ++ "specify a nick."
            , process = \args -> withMsg $ \msg -> do
                lift $ case words args of
                  [] -> writeMS M.empty
                  ns -> mapM_ (clearMessages . Msg.readNick msg) ns
                say "Messages purged."
            }
        ]
    moduleDefState  _ = return M.empty
    moduleSerialize _ = Just mapSerial

    -- | Hook onto contextual. Grab nicks of incoming messages, and tell them
    --   if they have any messages, if it's less than a day since we last did so.
    contextual _ _ = do
      sender <- getSender
      remp <- lift (needToRemind sender)
      if remp
         then withMsg (lift . flip doRemind sender) >>= mapM_ say
         else return ()

-- | Take a note and the current time, then display it
showNote :: Message m => m -> ClockTime -> Note -> String
showNote msg time note = res
    where diff         = time `diffClockTimes` noteTime note
          ago          = case timeDiffPretty diff of
                           [] -> "less than a minute"
                           pr -> pr
          action       = case noteType note of Tell -> "said"; Ask -> "asked"
          res          = printf "%s %s %s ago: %s"
                           (Msg.showNick msg $ noteSender note) action ago (noteContents note)

-- | Is it less than a day since we last reminded this nick they've got messages?
needToRemind :: Nick -> Tell Bool
needToRemind n = do
  st  <- readMS
  now <- io getClockTime
  return $ case M.lookup n st of
             Just (Just lastTime, _) ->
               let diff = now `diffClockTimes` lastTime
               in diff > noTimeDiff { tdDay = 1 }
             Just (Nothing,       _) -> True
             Nothing                 -> True

-- | Add a note to the NoticeBoard
writeDown :: Nick -> Nick -> String -> NoteType -> Tell ()
writeDown to from what ntype = do
  time <- io getClockTime
  let note = Note { noteSender   = from,
                    noteContents = what,
                    noteTime     = time,
                    noteType     = ntype }
  modifyMS (M.insertWith (\_ (_, ns) -> (Nothing, ns ++ [note]))
                         to (Nothing, [note]))

-- | Return a user's notes, or Nothing if they don't have any
getMessages :: Message m => m -> Nick -> Tell (Maybe [String])
getMessages msg n = do
  st   <- readMS
  time <- io getClockTime
  case M.lookup n st of
    Just (_, msgs) -> do
      -- update the last time we told this person they had messages
      writeMS $ M.insert n (Just time, msgs) st
      return . Just $ map (showNote msg time) msgs
    Nothing -> return Nothing

-- | Clear a user's messages.
clearMessages :: Nick -> Tell ()
clearMessages n = modifyMS (M.delete n)

-- * Handlers
--

-- | Give a user their messages
doMessages :: Message m => m -> Bool -> Tell [String]
doMessages msg loud = do
    msgs <- getMessages msg $ nick msg
    let res = fromMaybe ["You don't have any new messages."] msgs
    clearMessages (nick msg)
    if loud
        then return res
        else lift (ircPrivmsg (nick msg) (unlines res)) >> return []

-- | Execute a @tell or @ask command.
doTell :: Message m => String -> m -> NoteType -> Tell [String]
doTell args msg ntype = do
  let args'     = words args
      recipient = Msg.readNick msg (head args')
      sender    = nick msg
      rest      = unwords $ tail args'
      res | sender    == recipient   = Left "You can tell yourself!"
          | recipient == lambdabotName msg = Left "Nice try ;)"
          | otherwise                = Right "Consider it noted."
  when (isRight res) (writeDown recipient sender rest ntype)
  return [unEither res]

-- | Remind a user that they have messages.
doRemind :: Message m => m -> Nick -> Tell [String]
doRemind msg sender = do
  ms  <- getMessages msg sender
  now <- io getClockTime
  modifyMS (M.update (Just . first (const $ Just now)) sender)
  case ms of
             Just msgs ->
               let (messages, pronoun) =
                     if length msgs > 1
                       then ("messages", "them") else ("message", "it")
               in lift (ircPrivmsg sender (printf "You have %d new %s. '/msg %s @messages' to read %s."
                          (length msgs) messages (Msg.showNick msg $ lambdabotName msg) pronoun
                   :: String)) >> return []
             Nothing -> return []
