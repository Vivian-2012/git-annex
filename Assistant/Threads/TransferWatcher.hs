{- git-annex assistant transfer watching thread
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Threads.TransferWatcher where

import Common.Annex
import Assistant.ThreadedMonad
import Assistant.DaemonStatus
import Logs.Transfer
import Utility.DirWatcher
import Utility.Types.DirWatcher

import Data.Map as M

{- This thread watches for changes to the gitAnnexTransferDir,
 - and updates the DaemonStatus's map of ongoing transfers. -}
transferWatcherThread :: ThreadState -> DaemonStatusHandle -> IO ()
transferWatcherThread st dstatus = do
	g <- runThreadState st $ fromRepo id
	let dir = gitAnnexTransferDir g
	createDirectoryIfMissing True dir
	let hook a = Just $ runHandler st dstatus a
	let hooks = mkWatchHooks
		{ addHook = hook onAdd
		, delHook = hook onDel
		, errHook = hook onErr
		}
	void $ watchDir dir (const False) hooks id

type Handler = ThreadState -> DaemonStatusHandle -> FilePath -> Maybe FileStatus -> IO ()

{- Runs an action handler.
 -
 - Exceptions are ignored, otherwise a whole thread could be crashed.
 -}
runHandler :: ThreadState -> DaemonStatusHandle -> Handler -> FilePath -> Maybe FileStatus -> IO ()
runHandler st dstatus handler file filestatus = void $ do
        either print (const noop) =<< tryIO go
        where
                go = handler st dstatus file filestatus

{- Called when there's an error with inotify. -}
onErr :: Handler
onErr _ _ msg _ = error msg

{- Called when a new transfer information file is written. 
 -
 - When another thread of the assistant writes a transfer info file,
 - this will notice that too, but should skip it, because the thread
 - will be managing the transfer itself, and will have stored a more
 - complete TransferInfo than is stored in the file.
 -}
onAdd :: Handler
onAdd st dstatus file _ = case parseTransferFile file of
	Nothing -> noop
	Just t -> do
		minfo <- runThreadState st $ checkTransfer t
		pid <- getProcessID
		case minfo of
			Nothing -> noop -- transfer already finished
			Just info
				| transferPid info == Just pid -> noop
				| otherwise -> adjustTransfers st dstatus
				(M.insertWith' const t info)

{- Called when a transfer information file is removed. -}
onDel :: Handler
onDel st dstatus file _ = case parseTransferFile file of
	Nothing -> noop
	Just t -> adjustTransfers st dstatus (M.delete t)

adjustTransfers :: ThreadState -> DaemonStatusHandle -> (M.Map Transfer TransferInfo -> M.Map Transfer TransferInfo) -> IO ()
adjustTransfers st dstatus a = runThreadState st $ modifyDaemonStatus dstatus $
	\s -> s { currentTransfers = a (currentTransfers s) }