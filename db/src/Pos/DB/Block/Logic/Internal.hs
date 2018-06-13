{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE RecordWildCards     #-}

-- | Unsafe functions for block application/rollback, some constraint sets
-- and some utilities. Mostly needed for use in 'Pos.Lrc' -- using lrc
-- requires applying and rolling back blocks, but applying many blocks
-- requires triggering lrc recalculations.

module Pos.DB.Block.Logic.Internal
       (
         -- * Constraints
         MonadBlockBase
       , MonadBlockVerify
       , MonadBlockApply
       , MonadMempoolNormalization

       , applyBlocksUnsafe
       , normalizeMempool
       , rollbackBlocksUnsafe
       , BypassSecurityCheck(..)

       , toUpdateBlock
       , toTxpBlock
       , toSscBlock
       ) where

import           Universum

import           Control.Lens (each, _Wrapped)
import qualified Crypto.Random as Rand
import           Formatting (sformat, (%))
import           Serokell.Util.Text (listJson)
import           UnliftIO (MonadUnliftIO)

import           Pos.Chain.Block (Block, Blund, ComponentBlock (..),
                     GenesisBlock, IsGenesisHeader, MainBlock,
                     Undo (undoDlg, undoTx, undoUS), gbHeader, headerHash,
                     mainBlockDlgPayload, mainBlockSscPayload,
                     mainBlockTxPayload, mainBlockUpdatePayload)
import           Pos.Chain.Delegation (DlgBlock, DlgBlund, MonadDelegation)
import           Pos.Chain.Ssc (HasSscConfiguration, MonadSscMem, SscBlock)
import           Pos.Chain.Txp (TxpConfiguration)
import           Pos.Chain.Update (PollModifier)
import           Pos.Core as Core (Config (..), configBlkSecurityParam,
                     configEpochSlots, epochIndexL)
import           Pos.Core.Chrono (NE, NewestFirst (..), OldestFirst (..))
import           Pos.Core.Exception (assertionFailed)
import           Pos.Core.Reporting (MonadReporting)
import           Pos.Core.Update (BlockVersion, BlockVersionData)
import           Pos.DB (MonadDB, MonadDBRead, MonadGState, SomeBatchOp (..))
import           Pos.DB.Block.BListener (MonadBListener)
import           Pos.DB.Block.GState.SanityCheck (sanityCheckDB)
import           Pos.DB.Block.Slog.Logic (BypassSecurityCheck (..),
                     MonadSlogApply, MonadSlogBase, ShouldCallBListener,
                     slogApplyBlocks, slogRollbackBlocks)
import           Pos.DB.Delegation (dlgApplyBlocks, dlgNormalizeOnRollback,
                     dlgRollbackBlocks)
import qualified Pos.DB.GState.Common as GS (writeBatchGState)
import           Pos.DB.Lrc (HasLrcContext)
import           Pos.DB.Ssc (sscApplyBlocks, sscNormalize, sscRollbackBlocks)
import           Pos.DB.Txp.MemState (MonadTxpLocal (..))
import           Pos.DB.Txp.Settings (TxpBlock, TxpBlund,
                     TxpGlobalSettings (..))
import           Pos.DB.Update (UpdateBlock, UpdateContext, usApplyBlocks,
                     usNormalize, usRollbackBlocks)
import           Pos.Util (Some (..), spanSafe)
import           Pos.Util.Util (HasLens', lensOf)

-- | Set of basic constraints used by high-level block processing.
type MonadBlockBase ctx m
     = ( MonadSlogBase ctx m
       , MonadUnliftIO m
       -- Needed because SSC state is fully stored in memory.
       , MonadSscMem ctx m
       -- Needed to load blocks (at least delegation does it).
       , MonadDBRead m
       -- Needed by some components.
       , MonadGState m
       -- This constraints define block components' global logic.
       , HasLrcContext ctx
       , HasLens' ctx TxpGlobalSettings
       , MonadDelegation ctx m
       -- 'MonadRandom' for crypto.
       , Rand.MonadRandom m
       -- To report bad things.
       , MonadReporting m
       , HasSscConfiguration
       )

-- | Set of constraints necessary for high-level block verification.
type MonadBlockVerify ctx m = MonadBlockBase ctx m

-- | Set of constraints necessary to apply or rollback blocks at high-level.
-- Also normalize mempool.
type MonadBlockApply ctx m
     = ( MonadBlockBase ctx m
       , MonadSlogApply ctx m
       , MonadUnliftIO m
       -- It's obviously needed to write something to DB, for instance.
       , MonadDB m
       -- Needed for iteration over DB.
       , MonadMask m
       -- Needed to embed custom logic.
       , MonadBListener m
       )

type MonadMempoolNormalization ctx m
    = ( MonadSlogBase ctx m
      , MonadUnliftIO m
      , MonadTxpLocal m
      , MonadSscMem ctx m
      , HasLrcContext ctx
      , HasLens' ctx UpdateContext
      -- Needed to load useful information from db
      , MonadDBRead m
      , MonadGState m
      -- Needed for error reporting.
      , MonadReporting m
      -- 'MonadRandom' for crypto.
      , Rand.MonadRandom m
      , HasSscConfiguration
      )

-- | Normalize mempool.
normalizeMempool
    :: MonadMempoolNormalization ctx m
    => Core.Config
    -> TxpConfiguration
    -> m ()
normalizeMempool coreConfig txpConfig = do
    -- We normalize all mempools except the delegation one.
    -- That's because delegation mempool normalization is harder and is done
    -- within block application.
    sscNormalize coreConfig
    txpNormalize coreConfig txpConfig
    usNormalize

-- | Applies a definitely valid prefix of blocks. This function is unsafe,
-- use it only if you understand what you're doing. That means you can break
-- system guarantees.
--
-- Invariant: all blocks have the same epoch.
applyBlocksUnsafe
    :: ( MonadBlockApply ctx m
       )
    => Core.Config
    -> BlockVersion
    -> BlockVersionData
    -> ShouldCallBListener
    -> OldestFirst NE Blund
    -> Maybe PollModifier
    -> m ()
applyBlocksUnsafe coreConfig bv bvd scb blunds pModifier = do
    -- Check that all blunds have the same epoch.
    unless (null nextEpoch) $ assertionFailed $
        sformat ("applyBlocksUnsafe: tried to apply more than we should"%
                 "thisEpoch"%listJson%"\nnextEpoch:"%listJson)
                (map (headerHash . fst) thisEpoch)
                (map (headerHash . fst) nextEpoch)
    -- It's essential to apply genesis block separately, before
    -- applying other blocks.
    -- That's because applying genesis block may change protocol version
    -- which may potentially change protocol rules.
    -- We would like to avoid dependencies between components, so we have
    -- chosen this approach. Related issue is CSL-660.
    -- Also note that genesis block can be only in the head, because all
    -- blocks are from the same epoch.
    case blunds ^. _Wrapped of
        (b@(Left _,_):|[])     -> app' (b:|[])
        (b@(Left _,_):|(x:xs)) -> app' (b:|[]) >> app' (x:|xs)
        _                      -> app blunds
  where
    app x = applyBlocksDbUnsafeDo coreConfig bv bvd scb x pModifier
    app' = app . OldestFirst
    (thisEpoch, nextEpoch) =
        spanSafe ((==) `on` view (_1 . epochIndexL)) $ getOldestFirst blunds

applyBlocksDbUnsafeDo
    :: ( MonadBlockApply ctx m
       )
    => Core.Config
    -> BlockVersion
    -> BlockVersionData
    -> ShouldCallBListener
    -> OldestFirst NE Blund
    -> Maybe PollModifier
    -> m ()
applyBlocksDbUnsafeDo coreConfig bv bvd scb blunds pModifier = do
    let blocks = fmap fst blunds
    -- Note: it's important to do 'slogApplyBlocks' first, because it
    -- puts blocks in DB.
    slogBatch <- slogApplyBlocks (configBlkSecurityParam coreConfig) scb blunds
    TxpGlobalSettings {..} <- view (lensOf @TxpGlobalSettings)
    usBatch <- SomeBatchOp <$> usApplyBlocks coreConfig bv (map toUpdateBlock blocks) pModifier
    delegateBatch <- SomeBatchOp <$> dlgApplyBlocks (map toDlgBlund blunds)
    txpBatch <- tgsApplyBlocks $ map toTxpBlund blunds
    sscBatch <- SomeBatchOp <$>
        -- TODO: pass not only 'Nothing'
        sscApplyBlocks coreConfig bvd (map toSscBlock blocks) Nothing
    GS.writeBatchGState
        [ delegateBatch
        , usBatch
        , txpBatch
        , sscBatch
        , slogBatch
        ]
    sanityCheckDB

-- | Rollback sequence of blocks, head-newest order expected with head being
-- current tip. It's also assumed that lock on block db is taken already.
rollbackBlocksUnsafe
    :: MonadBlockApply ctx m
    => Core.Config
    -> BypassSecurityCheck -- ^ is rollback for more than k blocks allowed?
    -> ShouldCallBListener
    -> NewestFirst NE Blund
    -> m ()
rollbackBlocksUnsafe coreConfig bsc scb toRollback = do
    slogRoll <- slogRollbackBlocks (configProtocolConstants coreConfig)
                                   bsc
                                   scb
                                   toRollback
    dlgRoll <- SomeBatchOp <$> dlgRollbackBlocks (map toDlgBlund toRollback)
    usRoll <- SomeBatchOp <$> usRollbackBlocks
                  (toRollback & each._2 %~ undoUS
                              & each._1 %~ toUpdateBlock)
    TxpGlobalSettings {..} <- view (lensOf @TxpGlobalSettings)
    txRoll <- tgsRollbackBlocks $ map toTxpBlund toRollback
    sscBatch <- SomeBatchOp <$> sscRollbackBlocks (configEpochSlots coreConfig)
        (map (toSscBlock . fst) toRollback)
    GS.writeBatchGState
        [ dlgRoll
        , usRoll
        , txRoll
        , sscBatch
        , slogRoll
        ]
    -- After blocks are rolled back it makes sense to recreate the
    -- delegation mempool.
    -- We don't normalize other mempools, because they are normalized
    -- in 'applyBlocksUnsafe' and we always ensure that some blocks
    -- are applied after rollback.
    dlgNormalizeOnRollback $ configProtocolMagic coreConfig
    sanityCheckDB


toComponentBlock :: (MainBlock -> payload) -> Block -> ComponentBlock payload
toComponentBlock fnc block = case block of
    Left genBlock   -> ComponentBlockGenesis (convertGenesis genBlock)
    Right mainBlock -> ComponentBlockMain (Some $ mainBlock ^. gbHeader) (fnc mainBlock)

toTxpBlock :: Block -> TxpBlock
toTxpBlock = toComponentBlock (view mainBlockTxPayload)

toUpdateBlock :: Block -> UpdateBlock
toUpdateBlock = toComponentBlock (view mainBlockUpdatePayload)

toTxpBlund :: Blund -> TxpBlund
toTxpBlund = bimap toTxpBlock undoTx

toSscBlock :: Block -> SscBlock
toSscBlock = toComponentBlock (view mainBlockSscPayload)

toDlgBlund :: Blund -> DlgBlund
toDlgBlund = bimap toDlgBlock undoDlg
  where
    toDlgBlock :: Block -> DlgBlock
    toDlgBlock = toComponentBlock (view mainBlockDlgPayload)

convertGenesis :: GenesisBlock -> Some IsGenesisHeader
convertGenesis = Some . view gbHeader
