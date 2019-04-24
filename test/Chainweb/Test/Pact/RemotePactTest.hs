{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module: Chainweb.Test.RemotePactTest
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Unit test for Pact execution via the Http Pact interface (/send, etc.)(inprocess) API  in Chainweb
module Chainweb.Test.Pact.RemotePactTest where

import Control.Concurrent hiding (readMVar, putMVar)
import Control.Concurrent.Async
import Control.Concurrent.MVar.Strict
import Control.Exception
import Control.Lens
import Control.Monad

import qualified Data.Aeson as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Either
import qualified Data.HashMap.Strict as HM
import Data.Foldable (toList)
import Data.Int
import Data.IORef
import Data.Maybe
import Data.Proxy
import Data.Streaming.Network (HostPreference)
import Data.String.Conv (toS)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Network.HTTP.Client.TLS as HTTP
import Network.Connection as HTTP

import Numeric.Natural

import Prelude hiding (lookup)

import Servant.API
import Servant.Client

import System.FilePath
import System.IO.Extra
import System.LogLevel
import System.Time.Extra

import Test.Tasty.HUnit
import Test.Tasty
import Test.Tasty.Golden


import Chainweb.Test.Pact.Utils
import Pact.Types.API
import Pact.Types.Command
import Pact.Types.Util

-- internal modules

import Chainweb.ChainId
import Chainweb.Chainweb
import Chainweb.Chainweb.PeerResources
import Chainweb.Graph
import Chainweb.HostAddress
import Chainweb.Logger
import Chainweb.Mempool.Mempool
import Chainweb.Mempool.RestAPI.Client
import Chainweb.Miner.Config
import Chainweb.NodeId
import Chainweb.Pact.RestAPI
import Chainweb.Test.P2P.Peer.BootstrapConfig
import Chainweb.Test.Pact.Utils
import Chainweb.Test.Utils (testRocksDb)
import Chainweb.Utils
import Chainweb.Version

import Data.CAS.RocksDB

import P2P.Node.Configuration
import P2P.Peer

nNodes :: Natural
nNodes = 1

version :: ChainwebVersion
version = TestWithTime petersonChainGraph

cid :: HasCallStack => ChainId
cid = head . toList $ chainIds version

tests :: RocksDb -> IO TestTree
tests rdb = do
    peerInfoVar <- newEmptyMVar
    theAsync <- async $ runTestNodes rdb Warn version nNodes peerInfoVar
    link theAsync
    newPeerInfo <- readMVar peerInfoVar
    let thePort = _hostAddressPort (_peerAddr newPeerInfo)

    let cmds = apiCmds version cid
    let cwBaseUrl = getCwBaseUrl thePort
    cwEnv <- getClientEnv cwBaseUrl

    -------------------------------------------------------------------
     -- test: (send / poll / validated in mempool) for simple Pact command
    -------------------------------------------------------------------
    bsCmd <- bsCommandFromStr simpleCmdStr
    (tt0, rks) <- testSend cmds cwEnv bsCmd

    tt1 <- testPoll cmds cwEnv rks
    lastPar <- newIORef Nothing
    noopMp <- noopMempool
    let tConfig = mempoolTxConfig noopMp
    let mPool = toMempool version cid tConfig 10000 lastPar cwEnv :: MempoolBackend ChainwebTransaction
    let tt2 = testCase "mempoolValidationCheck" $ testMPValidated mPool rks

    -------------------------------------------------------------------
    -- test: send series of commands causing a fork
    -------------------------------------------------------------------
    fork0Cmd <- bsCommandFromFile "reintro-test.pact"
    sendNoCheck cmds cwEnv fork0Cmd
    -- TB continued

    return $ testGroup "PactRemoteTest" $ [tt0, tt1,tt2]

testSend :: PactTestApiCmds -> ClientEnv -> ByteString -> IO (TestTree, RequestKeys)
testSend cmds env bsCmd = do
    msb <- decodeStrictOrThrow bsCmd
    case msb of
        Nothing -> assertFailure "decoding command string failed"
        Just sb -> do
            result <- sendWithRetry cmds env sb
            case result of
                Left e -> assertFailure (show e)
                Right rks ->
                    return (checkRequestKeys "command-0" rks, rks)

sendNoCheck :: PactTestApiCmds -> ClientEnv -> ByteString -> Assertion
sendNoCheck cmds env bsCmd = do
    msb <- decodeStrictOrThrow bsCmd
    case msb of
        Nothing -> assertFailure "decoding command string failed"
        Just sb -> do
            result <- sendWithRetry cmds env sb
            if isRight result
              then return ()
              else assertFailure (show result)

testPoll :: PactTestApiCmds -> ClientEnv -> RequestKeys -> IO TestTree
testPoll cmds env rks = do
    response <- pollWithRetry cmds env rks
    case response of
        Left e -> assertFailure (show e)
        Right rsp -> return $ checkResponse "command-0" rks rsp

testMPValidated
    :: MempoolBackend ChainwebTransaction
    -> RequestKeys
    -> Assertion
testMPValidated mPool rks = do
    let txHashes = V.fromList $ TransactionHash . unHash . unRequestKey <$> _rkRequestKeys rks
    b <- go maxMempoolRetries mPool txHashes
    assertBool "At least one transaction was not validated" b
  where
    go :: Int -> MempoolBackend ChainwebTransaction -> Vector TransactionHash ->  IO Bool
    go 0 _ _ = return False
    go retries mp hashes = do
        results <- mempoolLookup mp hashes
        if checkValidated results then return True
        else do
            sleep 1
            go (retries - 1) mp hashes

maxMempoolRetries :: Int
maxMempoolRetries = 30

checkValidated :: Vector (LookupResult ChainwebTransaction) -> Bool
checkValidated results =
    not (null results) && V.all f results
  where
    f (Validated _) = True
    f Confirmed     = True
    f _             = False

getClientEnv :: BaseUrl -> IO ClientEnv
getClientEnv url = do
    let mgrSettings = HTTP.mkManagerSettings (HTTP.TLSSettingsSimple True False False) Nothing
    mgr <- HTTP.newTlsManagerWith mgrSettings
    return $ mkClientEnv mgr url

maxSendRetries :: Int
maxSendRetries = 30

-- | To allow time for node to startup, retry a number of times
sendWithRetry :: PactTestApiCmds -> ClientEnv -> SubmitBatch -> IO (Either ServantError RequestKeys)
sendWithRetry cmds env sb = go maxSendRetries
  where
    go retries =  do
        result <- runClientM (sendApiCmd cmds sb) env
        case result of
            Left _ ->
                if retries == 0 then do
                    putStrLn $ "send failing after " ++ show maxSendRetries ++ " retries"
                    return result
                else do
                    sleep 1
                    go (retries - 1)
            Right _ -> do
                putStrLn $ "send succeeded after " ++ show (maxSendRetries - retries) ++ " retries"
                return result

maxPollRetries :: Int
maxPollRetries = 30

-- | To allow time for node to startup, retry a number of times
pollWithRetry :: PactTestApiCmds -> ClientEnv -> RequestKeys -> IO (Either ServantError PollResponses)
pollWithRetry cmds env rks = do
  sleep 3
  go maxPollRetries
    where
      go retries = do
          result <- runClientM (pollApiCmd cmds (Poll (_rkRequestKeys rks))) env
          case result of
              Left _ ->
                  if retries == 0 then do
                      putStrLn $ "poll failing after " ++ show maxSendRetries ++ " retries"
                      return result
                  else do
                      sleep 1
                      go (retries - 1)
              Right _ -> do
                  putStrLn $ "poll succeeded after " ++ show (maxSendRetries - retries) ++ " retries"
                  return result

checkRequestKeys :: FilePath -> RequestKeys -> TestTree
checkRequestKeys filePrefix rks =
    goldenVsString (takeBaseName fp) (testPactFilesDir ++ fp) bsRks
  where
    fp = filePrefix ++ "-expected-rks.txt"
    bsRks = return $! foldMap (toS . show ) (_rkRequestKeys rks)

checkResponse :: FilePath -> RequestKeys -> PollResponses -> TestTree
checkResponse filePrefix rks (PollResponses theMap) =
    goldenVsString (takeBaseName fp) (testPactFilesDir ++ fp) bsResponse
  where
    fp = filePrefix ++ "-expected-resp.txt"
    mays = map (`HM.lookup` theMap) (_rkRequestKeys rks)
    values = _arResult <$> catMaybes mays
    bsResponse = return $! toS $! foldMap A.encode values


getCwBaseUrl :: Port -> BaseUrl
getCwBaseUrl thePort = BaseUrl
    { baseUrlScheme = Https
    , baseUrlHost = "127.0.0.1"
    , baseUrlPort = fromIntegral thePort
    , baseUrlPath = "" }

bsCommandFromStr :: String -> IO ByteString
bsCommandFromStr s = do
    testKeys <- testKeyPairs
    simpleBSCommand <- mkPactTransactionBS A.Null s testKeys "2019-04-23 20:23:13.964175 UTC"
    BS.putStrLn simpleBSCommand
    return simpleBSCommand

bsCommandFromFile :: String -> IO ByteString
bsCommandFromFile fName = do
    s <- readFile' $ testPactFilesDir ++ fName
    return $ toS $ (unwords . lines) s -- convert newlines to spaces

simpleCmdStr :: String
simpleCmdStr = "(+ 1 2)"

type PactClientApi
       = (SubmitBatch -> ClientM RequestKeys)
    :<|> ((Poll -> ClientM PollResponses)
    :<|> ((ListenerRequest -> ClientM ApiResult)
    :<|> (Command Text -> ClientM (CommandSuccess A.Value))))

generatePactApi :: ChainwebVersion -> ChainId -> PactClientApi
generatePactApi cwVersion chainid =
     case someChainwebVersionVal cwVersion of
        SomeChainwebVersionT (_ :: Proxy cv) ->
          case someChainIdVal chainid of
            SomeChainIdT (_ :: Proxy cid) -> client (Proxy :: Proxy (PactApi cv cid))

apiCmds :: ChainwebVersion -> ChainId -> PactTestApiCmds
apiCmds cwVersion theChainId =
    let sendCmd :<|> pollCmd :<|> _ :<|> _ = generatePactApi cwVersion theChainId
    in PactTestApiCmds sendCmd pollCmd

data PactTestApiCmds = PactTestApiCmds
    { sendApiCmd :: SubmitBatch -> ClientM RequestKeys
    , pollApiCmd :: Poll -> ClientM PollResponses }

----------------------------------------------------------------------------------------------------
-- test node(s), config, etc. for this test
----------------------------------------------------------------------------------------------------
runTestNodes
    :: RocksDb
    -> LogLevel
    -> ChainwebVersion
    -> Natural
    -> MVar PeerInfo
    -> IO ()
runTestNodes rdb loglevel v n portMVar =
    forConcurrently_ [0 .. int n - 1] $ \i -> do
        threadDelay (1000 * int i)
        let baseConf = config v n (NodeId i)
        conf <- if
            | i == 0 ->
                return $ bootstrapConfig baseConf
            | otherwise ->
                setBootstrapPeerInfo <$> readMVar portMVar <*> pure baseConf
        node rdb loglevel portMVar conf

node :: RocksDb -> LogLevel -> MVar PeerInfo -> ChainwebConfiguration -> IO ()
node rdb loglevel peerInfoVar conf = do
    rocksDb <- testRocksDb ("remotePactTest-" <> encodeUtf8 (toText nid)) rdb
    withChainweb conf logger rocksDb $ \cw -> do

        -- If this is the bootstrap node we extract the port number and publish via an MVar.
        when (nid == NodeId 0) $ do
            let bootStrapInfo = view (chainwebPeer . peerResPeer . peerInfo) cw
            putMVar peerInfoVar bootStrapInfo

        runChainweb cw `finally` do
            logFunctionText logger Info "write sample data"
            logFunctionText logger Info "shutdown node"
        return ()
  where
    nid = _configNodeId conf
    logger :: GenericLogger
    logger = addLabel ("node", toText nid) $ genericLogger loglevel print

host :: Hostname
host = unsafeHostnameFromText "::1"

interface :: HostPreference
interface = "::1"

config
    :: ChainwebVersion
    -> Natural
    -> NodeId
    -> ChainwebConfiguration
config v n nid = defaultChainwebConfiguration v
    & set configNodeId nid
    & set (configP2p . p2pConfigPeer . peerConfigHost) host
    & set (configP2p . p2pConfigPeer . peerConfigInterface) interface
    & set (configP2p . p2pConfigKnownPeers) mempty
    & set (configP2p . p2pConfigIgnoreBootstrapNodes) True
    & set (configP2p . p2pConfigMaxPeerCount) (n * 2)
    & set (configP2p . p2pConfigMaxSessionCount) 4
    & set (configP2p . p2pConfigSessionTimeout) 60
    & set (configMiner . enableConfigConfig . configTestMiners) (MinerCount n)
    & set (configTransactionIndex . enableConfigEnabled) True

bootstrapConfig :: ChainwebConfiguration -> ChainwebConfiguration
bootstrapConfig conf = conf
    & set (configP2p . p2pConfigPeer) peerConfig
    & set (configP2p . p2pConfigKnownPeers) []
  where
    peerConfig = head (bootstrapPeerConfig $ _configChainwebVersion conf)
        & set peerConfigPort 0
        & set peerConfigHost host

setBootstrapPeerInfo :: PeerInfo -> ChainwebConfiguration -> ChainwebConfiguration
setBootstrapPeerInfo =
    over (configP2p . p2pConfigKnownPeers) . (:)

-- for Stuart:
runGhci :: IO ()
runGhci = withTempRocksDb "ghci.RemotePactTests" $ \rdb -> tests rdb >>= defaultMain
