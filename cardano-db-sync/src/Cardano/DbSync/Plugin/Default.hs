{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Cardano.DbSync.Plugin.Default
  ( defDbSyncNodePlugin
  , insertDefaultBlock
  , rollbackToSlot
  ) where


import           Cardano.Prelude

import           Cardano.BM.Trace (Trace)

import qualified Cardano.Db as DB

import           Cardano.DbSync.Era.Byron.Insert (insertByronBlock)
import qualified Cardano.DbSync.Era.Shelley.Generic as Generic
import           Cardano.DbSync.Era.Shelley.Insert (insertShelleyBlock)
import           Cardano.DbSync.Rollback (rollbackToSlot)

import           Cardano.Sync.Api
import           Cardano.Sync.Error
import           Cardano.Sync.LedgerState
import           Cardano.Sync.Plugin
import           Cardano.Sync.Types
import           Cardano.Sync.Util

import           Control.Monad.Logger (LoggingT)

import           Database.Persist.Sql (SqlBackend)

import           Ouroboros.Consensus.Cardano.Block (HardForkBlock (..))

-- | The default SyncNodePlugin.
-- Does exactly what the cardano-db-sync node did before the plugin system was added.
-- The non-default node takes this structure and extends the lists.
defDbSyncNodePlugin :: SqlBackend -> SyncNodePlugin
defDbSyncNodePlugin backend =
  SyncNodePlugin
    { plugOnStartup = []
    , plugInsertBlock = [insertDefaultBlock backend]
    , plugRollbackBlock = [rollbackToSlot backend]
    }

-- -------------------------------------------------------------------------------------------------

insertDefaultBlock
    :: SqlBackend -> Trace IO Text -> SyncEnv -> [BlockDetails]
    -> IO (Either SyncNodeError ())
insertDefaultBlock backend tracer env blockDetails =
    DB.runDbAction backend (Just tracer) $
      traverseMEither insert blockDetails
  where
    insert
        :: BlockDetails
        -> ReaderT SqlBackend (LoggingT IO) (Either SyncNodeError ())
    insert (BlockDetails cblk details) = do
      -- Calculate the new ledger state to pass to the DB insert functions but do not yet
      -- update ledgerStateVar.
      lStateSnap <- liftIO $ applyBlock (envLedger env) cblk
      res <- case cblk of
                BlockByron blk ->
                  insertByronBlock tracer blk details
                BlockShelley blk ->
                  insertShelleyBlock tracer env (Generic.fromShelleyBlock blk) lStateSnap details
                BlockAllegra blk ->
                  insertShelleyBlock tracer env (Generic.fromAllegraBlock blk) lStateSnap details
                BlockMary blk ->
                  insertShelleyBlock tracer env (Generic.fromMaryBlock blk) lStateSnap details
      -- Now we update it in ledgerStateVar and (possibly) store it to disk.
      liftIO $ saveLedgerStateMaybe (envLedger env)
                    lStateSnap (isSyncedWithinSeconds details 60)
      pure res
