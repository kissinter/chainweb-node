{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Miner.Test
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--

module Chainweb.Miner.Test
( MinerConfig(..)
, configMeanBlockTimeSeconds
, defaultMinerConfig
, pMinerConfig
, miner
) where

import Configuration.Utils

import Control.Concurrent
import Control.Lens hiding ((.=))
import Control.Monad (when)
import Control.Monad.STM

import Data.Tuple.Strict (T2(..))
import Data.IORef
import Data.Reflection hiding (int)
import qualified Data.Text as T
import Data.Word (Word64)

import GHC.Generics (Generic)

import Numeric.Natural

import System.LogLevel
import qualified System.Random.MWC as MWC
import qualified System.Random.MWC.Distributions as MWC

import Text.Printf

-- internal modules

import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB (BlockHeaderDb)
import Chainweb.ChainId (ChainId, testChainId)
import Chainweb.Cut
import Chainweb.CutDB
import Chainweb.Difficulty (HashDifficulty(..), PowHashNat(..), HashTarget(..))
import Chainweb.Graph
import Chainweb.NodeId
import Chainweb.Time (getCurrentTimeIntegral)
import Chainweb.TreeDB.HashTarget (hashTarget)
import Chainweb.Utils
import Chainweb.WebBlockHeaderDB

import Data.DiGraph
import Data.LogMessage

-- -------------------------------------------------------------------------- --
-- Configuration of Example

data MinerConfig = MinerConfig
    { _configMeanBlockTimeSeconds :: !Natural
    , _configTrivialTarget :: !Bool
    }
    deriving (Show, Eq, Ord, Generic)

makeLenses ''MinerConfig

defaultMinerConfig :: MinerConfig
defaultMinerConfig = MinerConfig
    { _configMeanBlockTimeSeconds = 10
    , _configTrivialTarget = False
    }

instance ToJSON MinerConfig where
    toJSON o = object
        [ "meanBlockTimeSeconds" .= _configMeanBlockTimeSeconds o
        , "trivialTarget" .= _configTrivialTarget o
        ]

instance FromJSON (MinerConfig -> MinerConfig) where
    parseJSON = withObject "MinerConfig" $ \o -> id
        <$< configMeanBlockTimeSeconds ..: "meanBlockTimeSeconds" % o
        <*< configTrivialTarget ..: "configTrivialTarget" % o

pMinerConfig :: MParser MinerConfig
pMinerConfig = id
    <$< configMeanBlockTimeSeconds .:: option auto
        % long "mean-block-time"
        <> short 'b'
        <> help "mean time for mining a block seconds"
    <*< configTrivialTarget .:: boolOption_
        % long "trivial-target"
        <> short 't'
        <> help "whether to use trivial difficulty targets (i.e. maxBound)"

-- -------------------------------------------------------------------------- --
-- Miner

miner
    :: LogFunction
    -> MinerConfig
    -> NodeId
    -> CutDb
    -> WebBlockHeaderDb
    -> IO ()
miner logFun conf nid cutDb wcdb = do
    logg Info "Started Miner"
    gen <- MWC.createSystemRandom
    give wcdb $ go gen 1
  where
    logg :: LogLevel -> T.Text -> IO ()
    logg = logFun

    graph :: ChainGraph
    graph = _chainGraph cutDb

    go :: Given WebBlockHeaderDb => MWC.GenIO -> Int -> IO ()
    go gen !i = do

        -- artificially delay the mining process when using a trivial target
        --
        when (_configTrivialTarget conf) $ do
            d <- MWC.geometric1
                (int (order graph) / (int (_configMeanBlockTimeSeconds conf) * 1000000))
                gen
            threadDelay d

        -- Calculate the hash difficulty for the chosen Chain
        --
        nonce0 <- MWC.uniform gen
        counter <- newIORef (1 :: Int)

        go' gen i nonce0 counter

    go' :: Given WebBlockHeaderDb => MWC.GenIO -> Int -> Word64 -> IORef Int -> IO ()
    go' gen !i !nonce0 counter = do

        -- create new (test) block header
        --
        let mine :: Word64 -> IO (Either Word64 Cut)
            mine !nonce = do
                ct <- getCurrentTimeIntegral

                -- get current longest cut
                --
                c <- _cut cutDb

                -- pick ChainId to mine on
                --
                -- chose randomly
                --
                cid <- randomChainId c

                let !p = c ^?! ixg cid  -- The parent block the mine on
                target <- getTarget cid p

                let thing :: String
                    thing = printf "%0256b" $ tiggy target

                -- Loops (i.e. "mines") if a non-matching nonce was generated
                testMine (Nonce nonce) target ct nid cid c >>= \case
                    Left BadNonce -> do
                        -- TODO Move nonce retrying inside of `testMine`!
                        atomicModifyIORef' counter (\n -> (succ n, ()))
                        mine $! succ nonce
                    Left BadAdjacents -> pure (Left nonce)
                    Right (T2 newBh newCut) -> do
                        total <- readIORef counter
                        when (cid == testChainId 0) $ do
                          printf "\n--- NODE:%02d success! HASHES:%06x TARGET:%s...%s PARENT-H:%03x PARENT-W:%06x PARENT:%s NEW:%s\n" (_nodeIdId nid) total (take 30 thing) (drop 226 thing) (pheight p) (pweight p) (take 8 . drop 5 . show $ _blockHash p) (take 8 . drop 5 . show $ _blockHash newBh)
                        return $! Right newCut

        mine nonce0 >>= \case
          Left nonce -> go' gen i nonce counter
          Right c' -> do
              logg Info $! "created new block" <> sshow i

              -- public cut into CutDb (add to queue)
              --
              atomically $! addCutHashes cutDb (cutToCutHashes Nothing c')

              -- continue
              --
              go gen (i + 1)

    -- | Number of set bits in the `HashTarget`. The more bits, the easier it is.
    tiggy :: HashTarget -> Integer
    tiggy (HashTarget (PowHashNat w)) = fromIntegral w

    pheight :: BlockHeader -> Word64
    pheight bh = case _blockHeight bh of BlockHeight w -> w

    pweight :: BlockHeader -> Integer
    pweight bh = case _blockWeight bh of
        BlockWeight (HashDifficulty (PowHashNat w)) -> int w

    getTarget :: ChainId -> BlockHeader -> IO HashTarget
    getTarget cid bh
        | _configTrivialTarget conf = pure (_blockTarget bh)
        | otherwise = case blockDb cid of
              Nothing -> pure (_blockTarget bh)
              -- Just db -> hashTargetFromHistory db bh timeSpan
              Just db -> hashTarget db bh

    blockDb :: ChainId -> Maybe BlockHeaderDb
    blockDb cid = wcdb ^? webBlockHeaderDb . ix cid
