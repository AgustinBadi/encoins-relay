{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE ImplicitParams    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeFamilies      #-}

module Encoins.Relay.Server.ServerSpec where

import           Cardano.Server.Client.Handle   (HasServantClientEnv)
import           Cardano.Server.Client.Internal (ServerEndpoint (ServerTxE))
import           Cardano.Server.Internal        (Env (envLogger), ServerM, loadEnv, runServerM)
import           Cardano.Server.Utils.Logger    (logSmth, mutedLogger, (.<))
import           Cardano.Server.Utils.Wait      (waitTime)
import           Control.Exception              (try)
import           Control.Monad                  (join, replicateM)
import           Control.Monad.IO.Class         (MonadIO (..))
import           Data.Bifunctor                 (Bifunctor (bimap, first))
import           Data.Either                    (isLeft, isRight)
import           Data.Fixed                     (Pico)
import           Data.List                      (partition)
import           Data.List.Extra                (dropSuffix, partition)
import           Data.String                    (IsString (..))
import qualified Data.Time                      as Time
import           ENCOINS.BaseTypes              (MintingPolarity (Mint))
import           ENCOINS.Core.V1.OffChain       (EncoinsMode (..))
import           Encoins.Relay.Client.Client    (TxClientCosntraints, secretsToReqBody, sendTxClientRequest, termsToSecrets,
                                                 txClientRedeemer)
import           Encoins.Relay.Client.Opts      (EncoinsRequestTerm (RPBurn))
import           Encoins.Relay.Client.Secrets   (HasEncoinsMode, getEncoinsTokensFromMode, mkSecretFile,
                                                 randomMintTerm)
import           Encoins.Relay.Server.Server    (EncoinsApi, mkServerHandle)
import           Internal                       (runEncoinsServerM)
import           Ledger                         (Ada, Address, TokenName)
import           Ledger.Value                   (TokenName (..), getValue)
import           PlutusAppsExtra.IO.ChainIndex  (getAdaAt, getValueAt)
import           PlutusAppsExtra.IO.Wallet      (getWalletAda)
import qualified PlutusTx.AssocMap              as PAM
import           System.Directory               (listDirectory)
import           System.Random                  (randomRIO)
import           Test.Hspec                     (Expectation, Spec, context, describe, expectationFailure, hspec, it,
                                                 shouldBe, shouldSatisfy)
import           Test.Hspec.Core.Spec           (sequential)

spec :: HasServantClientEnv => Spec
spec = describe "serverTx endpoint" $ do

    context "wallet mode" $ let ?mode = WalletMode in sequential $ do

        it "mint tokens" propMint

        it "burn tokens" propBurn

    context "ledger mode" $ let ?mode = LedgerMode in sequential $ do

        it "mint tokens" propMint

        it "burn tokens" propBurn

propMint :: (TxClientCosntraints ServerTxE, HasEncoinsMode) => Expectation
propMint = join $ runEncoinsServerM $ do
    l        <- randomRIO (1,4)
    terms    <- replicateM l randomMintTerm
    secrets  <- termsToSecrets terms
    sendTxClientRequest @ServerTxE secrets >>= \case
        Left err -> pure $ expectationFailure $ show err
        Right _ -> do
            mapM_ (uncurry mkSecretFile) secrets
            ((_,(v, inputs),_,_),_) <- secretsToReqBody secrets
            currentTime  <- liftIO Time.getCurrentTime
            tokensMinted <- confirmTokens currentTime $ map (first TokenName) inputs
            pure $ tokensMinted `shouldBe` True

propBurn :: (TxClientCosntraints ServerTxE, HasEncoinsMode) => Expectation
propBurn = join $ runEncoinsServerM $ do
    terms    <- map (RPBurn . Right . ("secrets/" <>)) <$> liftIO (listDirectory "secrets")
    secrets  <- termsToSecrets terms
    sendTxClientRequest @ServerTxE secrets >>= \case
        Left err -> pure $ expectationFailure $ show err
        Right _ -> do
            ((_,(v, inputs),_,_),_) <- secretsToReqBody secrets
            currentTime  <- liftIO Time.getCurrentTime
            tokensBurned <- confirmTokens currentTime $ map (first TokenName) inputs
            pure $ tokensBurned `shouldBe` True

maxConfirmationTime :: Pico -- Seconds
maxConfirmationTime = 120

confirmTokens :: HasEncoinsMode => Time.UTCTime -> [(TokenName, MintingPolarity)] -> ServerM EncoinsApi Bool
confirmTokens startTime tokens = do
    currentTime <- liftIO Time.getCurrentTime
    let (mustBeMinted, mustBeBurnt) = bimap (map fst) (map fst) $ partition ((== Mint) . snd) tokens
    if Time.nominalDiffTimeToSeconds (Time.diffUTCTime currentTime startTime) > maxConfirmationTime
    then pure False
    else do
        tokensIn <- getEncoinsTokensFromMode
        if all (`elem` tokensIn) mustBeMinted && all (`notElem` tokensIn) mustBeBurnt
        then pure True
        else confirmTokens startTime tokens