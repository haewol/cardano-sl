{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeOperators       #-}

module Main
       ( main
       ) where

import           Universum

import           Data.Maybe           (fromJust)
import           Formatting           (sformat, shown, (%))
import           Mockable             (Production, currentTime, runProduction)
import           System.Wlog          (logDebug, logInfo, logWarning)

import           Pos.Binary           ()
import           Pos.Client.CLI       (CommonNodeArgs (..), NodeArgs (..),
                                       SimpleNodeArgs (..))
import qualified Pos.Client.CLI       as CLI
import           Pos.Communication    (OutSpecs, WorkerSpec)
import           Pos.Core             (GenesisData (..), Timestamp (..), genesisData)
import           Pos.Launcher         (HasConfigurations, NodeParams (..), loggerBracket,
                                       runNodeReal, withConfigurations)
import           Pos.NtpCheck         (NtpStatus (..), withNtpCheck)
import           Pos.Ssc.Class        (SscConstraint, SscParams)
import           Pos.Ssc.GodTossing   (SscGodTossing)
import           Pos.Ssc.NistBeacon   (SscNistBeacon)
import           Pos.Ssc.SscAlgo      (SscAlgo (..))
import           Pos.Update           (updateTriggerWorker)
import           Pos.Util.CompileInfo (HasCompileInfo, retrieveCompileTimeInfo,
                                       withCompileInfo)
import           Pos.Util.UserSecret  (usVss)
import           Pos.WorkMode         (EmptyMempoolExt, RealMode)


actionWithoutWallet
    :: forall ssc.
       ( SscConstraint ssc
       , HasConfigurations
       , HasCompileInfo
       )
    => SscParams ssc
    -> NodeParams
    -> Production ()
actionWithoutWallet sscParams nodeParams =
    runNodeReal @ssc nodeParams sscParams plugins
  where
    plugins :: ([WorkerSpec (RealMode ssc EmptyMempoolExt)], OutSpecs)
    plugins = updateTriggerWorker

action
    :: ( HasConfigurations
       , HasCompileInfo
       )
    => SimpleNodeArgs
    -> Production ()
action (SimpleNodeArgs (cArgs@CommonNodeArgs {..}) (nArgs@NodeArgs {..})) = do
    whenJust cnaDumpGenesisDataPath $ CLI.dumpGenesisData
    logInfo $ sformat ("System start time is " % shown) $ gdStartTime genesisData
    t <- currentTime
    logInfo $ sformat ("Current time is " % shown) (Timestamp t)
    currentParams <- CLI.getNodeParams cArgs nArgs
    logInfo $ "Running using " <> show sscAlgo
    logInfo "Wallet is disabled, because software is built w/o it"
    logInfo $ sformat ("Using configs and genesis:\n"%shown) (CLI.configurationOptions (CLI.commonArgs cArgs))

    let vssSK = fromJust $ npUserSecret currentParams ^. usVss
    let gtParams = CLI.gtSscParams cArgs vssSK (npBehaviorConfig currentParams)

    let onNtpStatus = \case
            NtpSyncOk -> logDebug $
                      -- putText  $ -- FIXME: for some reason this message isn't printed
                                    -- when using 'logDebug', but a simple 'putText' works
                                    -- just fine.
                "Local time is in sync with the NTP server"
            NtpDesync diff -> logWarning $
                "Local time is severely off sync with the NTP server: " <> show diff
    withNtpCheck onNtpStatus $ case sscAlgo of
        NistBeaconAlgo ->
            actionWithoutWallet @SscNistBeacon () currentParams
        GodTossingAlgo ->
            actionWithoutWallet @SscGodTossing gtParams currentParams

main :: IO ()
main = withCompileInfo $(retrieveCompileTimeInfo) $ do
    args@(CLI.SimpleNodeArgs commonNodeArgs _) <- CLI.getSimpleNodeOptions
    let loggingParams = CLI.loggingParams "node" commonNodeArgs
    let conf = CLI.configurationOptions (CLI.commonArgs commonNodeArgs)
    loggerBracket loggingParams . runProduction $ do
        CLI.printFlags
        withConfigurations conf $ action args
