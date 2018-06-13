{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies    #-}

-- | Functions for operating with transactions

module Pos.Client.Txp.Network
       ( TxMode
       , prepareMTx
       , prepareUnsignedTx
       , prepareRedemptionTx
       , submitTxRaw
       , sendTxOuts
       ) where

import           Universum

import           Formatting (build, sformat, (%))
import           System.Wlog (logInfo)

import           Pos.Client.Txp.Addresses (MonadAddresses (..))
import           Pos.Client.Txp.Balances (MonadBalances (..), getOwnUtxo)
import           Pos.Client.Txp.History (MonadTxHistory (..))
import           Pos.Client.Txp.Util (InputSelectionPolicy,
                     PendingAddresses (..), TxCreateMode, TxError (..),
                     createMTx, createRedemptionTx, createUnsignedTx)
import           Pos.Communication.Types (InvOrDataTK)
import           Pos.Core as Core (Address, Coin, Config, makeRedeemAddress,
                     mkCoin, unsafeAddCoin)
import           Pos.Core.Txp (Tx, TxAux (..), TxId, TxMsgContents (..),
                     TxOut (..), TxOutAux (..), txaF)
import           Pos.Crypto (ProtocolMagic, RedeemSecretKey, SafeSigner, hash,
                     redeemToPublic)
import           Pos.Infra.Communication.Protocol (OutSpecs)
import           Pos.Infra.Communication.Specs (createOutSpecs)
import           Pos.Infra.Diffusion.Types (Diffusion (sendTx))
import           Pos.Util.Util (eitherToThrow)
import           Pos.WorkMode.Class (MinWorkMode)

type TxMode m
    = ( MinWorkMode m
      , MonadBalances m
      , MonadTxHistory m
      , MonadMask m
      , MonadThrow m
      , TxCreateMode m
      )

-- | Construct Tx using multiple secret keys and given list of desired outputs.
prepareMTx
    :: TxMode m
    => Core.Config
    -> (Address -> Maybe SafeSigner)
    -> PendingAddresses
    -> InputSelectionPolicy
    -> NonEmpty Address
    -> NonEmpty TxOutAux
    -> AddrData m
    -> m (TxAux, NonEmpty TxOut)
prepareMTx coreConfig hdwSigners pendingAddrs inputSelectionPolicy addrs outputs addrData = do
    utxo <- getOwnUtxos (toList addrs)
    eitherToThrow =<<
        createMTx coreConfig pendingAddrs inputSelectionPolicy utxo hdwSigners outputs addrData

-- | Construct unsigned Tx
prepareUnsignedTx
    :: TxMode m
    => Core.Config
    -> PendingAddresses
    -> InputSelectionPolicy
    -> NonEmpty Address
    -> NonEmpty TxOutAux
    -> Address
    -> m (Either TxError (Tx, NonEmpty TxOut))
prepareUnsignedTx coreConfig pendingAddrs inputSelectionPolicy addrs outputs changeAddress = do
    utxo <- getOwnUtxos (toList addrs)
    createUnsignedTx coreConfig pendingAddrs inputSelectionPolicy utxo outputs changeAddress

-- | Construct redemption Tx using redemption secret key and a output address
prepareRedemptionTx
    :: TxMode m
    => ProtocolMagic
    -> RedeemSecretKey
    -> Address
    -> m (TxAux, Address, Coin)
prepareRedemptionTx pm rsk output = do
    let redeemAddress = makeRedeemAddress $ redeemToPublic rsk
    utxo <- getOwnUtxo redeemAddress
    let addCoin c = unsafeAddCoin c . txOutValue . toaOut
        redeemBalance = foldl' addCoin (mkCoin 0) utxo
        txOuts = one $
            TxOutAux {toaOut = TxOut output redeemBalance}
    when (redeemBalance == mkCoin 0) $ throwM RedemptionDepleted
    txAux <- eitherToThrow =<< createRedemptionTx pm utxo rsk txOuts
    pure (txAux, redeemAddress, redeemBalance)

-- | Send the ready-to-use transaction
submitTxRaw
    :: (MinWorkMode m)
    => Diffusion m -> TxAux -> m Bool
submitTxRaw diffusion txAux@TxAux {..} = do
    let txId = hash taTx
    logInfo $ sformat ("Submitting transaction: "%txaF) txAux
    logInfo $ sformat ("Transaction id: "%build) txId
    sendTx diffusion txAux

sendTxOuts :: OutSpecs
sendTxOuts = createOutSpecs (Proxy :: Proxy (InvOrDataTK TxId TxMsgContents))
