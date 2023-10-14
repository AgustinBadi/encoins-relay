{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Encoins.Relay.Apps.Internal where

import           Cardano.Api                        (NetworkId, writeFileJSON)
import           Control.Concurrent                 (threadDelay)
import           Control.Exception                  (AsyncException (UserInterrupt), Exception (..), SomeException)
import           Control.Monad                      (forM)
import           Control.Monad.Catch                (MonadCatch, MonadThrow (throwM), handle, try)
import           Control.Monad.IO.Class             (MonadIO (liftIO))
import           Data.Aeson                         (FromJSON (parseJSON), ToJSON, eitherDecodeFileStrict)
import           Data.Aeson.Types                   (parseMaybe)
import           Data.Default                       (def)
import           Data.Maybe                         (catMaybes)
import           Data.Text                          (Text)
import qualified Data.Text.Lazy                     as TL
import           Data.Time                          (getCurrentTime)
import           Ledger                             (Slot (getSlot))
import           Plutus.V2.Ledger.Api               (CurrencySymbol, TokenName)
import           PlutusAppsExtra.IO.ChainIndex.Kupo (CreatedOrSpent (..), KupoRequest (..), SpentOrUnspent (..), getKupoResponse)
import           PlutusAppsExtra.Utils.Kupo         (KupoResponse (..), kupoResponseToJSON)
import           System.Directory                   (createDirectoryIfMissing)
import           System.ProgressBar                 (Progress (..), ProgressBarWidth (..), Style (..), defStyle, exact,
                                                     incProgress, msg, newProgressBar)

encoinsTokenName :: TokenName
encoinsTokenName = "ENCS"

-- Mainnet only
encoinsCS :: CurrencySymbol
encoinsCS = "9abf0afd2f236a19f2842d502d0450cbcd9c79f123a9708f96fd9b96"

getResponsesIO :: (MonadIO m, MonadCatch m) => NetworkId -> Slot -> Slot -> Slot -> m [KupoResponse]
getResponsesIO networkId slotFrom slotTo slotDelta = do
    liftIO $ createDirectoryIfMissing True "savedResponses"
    pb <- liftIO $ newProgressBar (progressBarStyle "Getting reponses") 10 (Progress 0 (length intervals) ())
    resValue <- fmap concat $ forM intervals $ \(from, to) -> reloadHandler $ do
        let fileName = "response" <> show (getSlot from) <> "_"  <> show (getSlot to) <> ".json"
            req :: KupoRequest 'SUSpent 'CSCreated 'CSCreated
            req = def{reqCreatedOrSpentAfter = Just from, reqCreatedOrSpentBefore = Just to}
        r <- withResultSaving ("savedResponses/" <> fileName) $ liftIO $
            fmap (kupoResponseToJSON networkId) <$> getKupoResponse req
        liftIO $ incProgress pb 1
        pure r
    pure $ catMaybes $ parseMaybe parseJSON <$> resValue
    where
        intervals = divideTimeIntoIntervals slotFrom slotTo slotDelta
        mkLog = liftIO . putStrLn
        reloadHandler ma = (`handle` ma) $ \e -> case fromException e of
            Just UserInterrupt -> throwM UserInterrupt
            _ -> do
                ct <- liftIO getCurrentTime
                mkLog (show ct <> "\n" <> show e <> "\n(Handled)")
                liftIO (threadDelay 5_000_000)
                reloadHandler ma

withResultSaving :: (MonadIO m, FromJSON a, ToJSON a) => FilePath -> m a -> m a
withResultSaving fp action =
    liftIO (try @_ @SomeException $ either error id <$> eitherDecodeFileStrict fp)
        >>= either doAction pure
    where
        doAction _ = do
            res <- action
            _   <- liftIO $ writeFileJSON fp res
            pure res

-- Divide time into intervals such that each interval except the first is a multiple of delta.
divideTimeIntoIntervals :: Slot -> Slot -> Slot -> [(Slot, Slot)]
divideTimeIntoIntervals from to delta
    | from > to         = []
    | to - from < delta = [(from, to)]
    | from /= from'     = (from, from' - 1) : divideTimeIntoIntervals from' to delta
    | otherwise         = zip (init xs) (subtract 1 <$> tail xs) <> [(last xs, to)]
    where
        -- First delta multiplier
        from' = head [x | x <- [from ..], x `mod` delta == 0]
        xs = [from, from + delta .. to]

defaultSlotConfigFilePath :: FilePath
defaultSlotConfigFilePath = "../plutus-chain-index/plutus-chain-index-config.json"

progressBarStyle :: Text -> Style s
progressBarStyle m = defStyle
    { stylePrefix  = msg $ TL.fromStrict m
    , styleWidth   = ConstantWidth 100
    , stylePostfix = exact
    }