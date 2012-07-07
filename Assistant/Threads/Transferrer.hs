{- git-annex assistant data transferrer thread
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Threads.Transferrer where

import Common.Annex
import Assistant.ThreadedMonad
import Assistant.DaemonStatus
import Assistant.TransferQueue
import Assistant.TransferSlots
import Logs.Transfer
import Annex.Content
import Command
import qualified Command.Move

import Data.Time.Clock
import qualified Data.Map as M

{- For now only one transfer is run at a time. -}
maxTransfers :: Int
maxTransfers = 1

{- Dispatches transfers from the queue. -}
transfererThread :: ThreadState -> DaemonStatusHandle -> TransferQueue -> TransferSlots -> IO ()
transfererThread st dstatus transferqueue slots = go
	where
		go = do
			(t, info) <- getNextTransfer transferqueue
			whenM (runThreadState st $ shouldTransfer dstatus t) $
				void $ inTransferSlot slots $
					runTransfer st dstatus t info
			go

{- Checks if the requested transfer is already running, or
 - the file to download is already present. -}
shouldTransfer :: DaemonStatusHandle -> Transfer -> Annex Bool
shouldTransfer dstatus t = go =<< currentTransfers <$> getDaemonStatus dstatus
	where
		go m
			| M.member t m = return False
			| transferDirection t == Download =
				not <$> inAnnex (transferKey t)
			| otherwise = return True

{- A transfer is run in a separate process, with a *copy* of the Annex
 - state. This is necessary to avoid blocking the rest of the assistant
 - on the transfer completing, and also to allow multiple transfers to run
 - at once. 
 -
 - However, it means that the transfer processes are responsible
 - for doing any necessary shutdown cleanups, and that the parent
 - thread's cache must be invalidated once a transfer completes, as
 - changes may have been made to the git-annex branch. 
 -
 - Currently a minimal shutdown is done; the transfer processes are
 - effectively running in oneshot mode, without committing changes to the
 - git-annex branch, and transfers should never queue git commands to run.
 -}
runTransfer :: ThreadState -> DaemonStatusHandle -> Transfer -> TransferInfo -> IO ()
runTransfer st dstatus t info
	| transferDirection t == Download = go Command.Move.fromStart
	| otherwise = go Command.Move.toStart
	where
		go cmd = case (transferRemote info, associatedFile info) of
			(Nothing, _) -> noop
			(_, Nothing) -> noop
			(Just remote, Just file) -> do
				now <- getCurrentTime
				pid <- unsafeForkProcessThreadState st $
					doCommand $ cmd remote False file (transferKey t)
				runThreadState st $ 
					adjustTransfers dstatus $
						M.insertWith' const t info
							{ startedTime = Just now
							, transferPid = Just pid
							, shouldWait = True
							}