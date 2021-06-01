{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-partial-fields -Wno-unused-matches -Wno-deprecations -Wno-unused-local-binds -Wno-incomplete-record-updates #-}
module Cardano.Unlog.BlockProp (module Cardano.Unlog.BlockProp) where

import           Prelude (String, error, head, tail, id)
import           Cardano.Prelude hiding (head)

import           Control.Arrow ((&&&), (***))
import           Control.Concurrent.Async (mapConcurrently)
import           Data.Aeson (toJSON)
import qualified Data.Aeson as AE
import           Data.Function (on)
import           Data.Either (partitionEithers, isLeft, isRight)
import           Data.Maybe (catMaybes, mapMaybe)
import           Data.Tuple (swap)
import           Data.Vector (Vector)
import qualified Data.Vector as Vec
import qualified Data.Map.Strict as Map

import           Data.Time.Clock (NominalDiffTime, UTCTime)
import qualified Data.Time.Clock as Time

import           Ouroboros.Network.Block (BlockNo(..), SlotNo(..))

import           Data.Accum
import           Data.Distribution
import           Cardano.Profile
import           Cardano.Unlog.LogObject
import           Cardano.Unlog.Resources
import           Cardano.Unlog.SlotStats

import qualified Debug.Trace as D
import qualified Text.Printf as D


data BlockPropagation
  = BlockPropagation
    { sForgerForges        :: !(Distribution Float NominalDiffTime)
    , sForgerAdoptions     :: !(Distribution Float NominalDiffTime)
    , sForgerAnnouncements :: !(Distribution Float NominalDiffTime)
    , sForgerSends         :: !(Distribution Float NominalDiffTime)
    , sPeerNotices         :: !(Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
    , sPeerFetches         :: !(Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
    , sPeerAdoptions       :: !(Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
    , sPeerAnnouncements   :: !(Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
    , sPeerSends           :: !(Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
    }
  deriving Show

instance AE.ToJSON BlockPropagation where
  toJSON BlockPropagation{..} = AE.Array $ Vec.fromList
    [ extendObject "kind" "forgerForges"        $ toJSON sForgerForges
    , extendObject "kind" "forgerAdoptions"     $ toJSON sForgerAdoptions
    , extendObject "kind" "forgerAnnouncements" $ toJSON sForgerAnnouncements
    , extendObject "kind" "forgerSends"         $ toJSON sForgerSends
    , extendObject "kind" "peerNoticesMean"       $ toJSON (fst sPeerNotices)
    , extendObject "kind" "peerNoticesCoV"        $ toJSON (snd sPeerNotices)
    , extendObject "kind" "peerFetchesMean"       $ toJSON (fst sPeerFetches)
    , extendObject "kind" "peerFetchesCoV"        $ toJSON (snd sPeerFetches)
    , extendObject "kind" "peerAdoptionsMean"     $ toJSON (fst sPeerAdoptions)
    , extendObject "kind" "peerAdoptionsCoV"      $ toJSON (snd sPeerAdoptions)
    , extendObject "kind" "peerAnnouncementsMean" $ toJSON (fst sPeerAnnouncements)
    , extendObject "kind" "peerAnnouncementsCoV"  $ toJSON (snd sPeerAnnouncements)
    , extendObject "kind" "peerSendsMean"         $ toJSON (fst sPeerSends)
    , extendObject "kind" "peerSendsCoV"          $ toJSON (snd sPeerSends)
    ]

-- | Block's events, as seen by its forger.
data BlockForgerEvents
  =  BlockForgerEvents
  { bfeHost       :: !Host
  , bfeBlock      :: !Hash
  , bfeBlockPrev  :: !Hash
  , bfeBlockNo    :: !BlockNo
  , bfeSlotNo     :: !SlotNo
  , bfeSlotStart  :: !UTCTime
  , bfeForged     :: !(Maybe UTCTime)
  , bfeAdopted    :: !(Maybe UTCTime)
  , bfeChainDelta :: !Int
  , bfeAnnounced  :: !(Maybe UTCTime)
  , bfeSent       :: !(Maybe UTCTime)
  }
  deriving (Generic, AE.FromJSON, AE.ToJSON, Show)

bfePrevBlock :: BlockForgerEvents -> Maybe Hash
bfePrevBlock x = case bfeBlockNo x of
  0 -> Nothing
  _ -> Just $ bfeBlockPrev x

-- | Block's events, as seen by an observer.
data BlockObserverEvents
  =  BlockObserverEvents
  { boeHost       :: !Host
  , boeBlock      :: !Hash
  , boeBlockNo    :: !BlockNo
  , boeSlotNo     :: !SlotNo
  , boeSlotStart  :: !UTCTime
  , boeNoticed    :: !(Maybe UTCTime)
  , boeFetched    :: !(Maybe UTCTime)
  , boeAdopted    :: !(Maybe UTCTime)
  , boeChainDelta :: !Int
  , boeAnnounced  :: !(Maybe UTCTime)
  , boeSent       :: !(Maybe UTCTime)
  }
  deriving (Generic, AE.FromJSON, AE.ToJSON, Show)

-- | Sum of observer and forger events alike.
type MachBlockEvents = Either BlockObserverEvents BlockForgerEvents

mbeIsForger :: MachBlockEvents -> Bool
mbeIsForger = isRight

ordBlockEv :: MachBlockEvents -> MachBlockEvents -> Ordering
ordBlockEv l r =
  if      (on (>) $ either boeBlockNo bfeBlockNo) l r then GT
  else if (on (>) $ either boeBlockNo bfeBlockNo) r l then LT
  else if isRight l then GT
  else if isRight r then LT
  else EQ

mbeBlockHash :: MachBlockEvents -> Hash
mbeBlockHash = either boeBlock bfeBlock

mbeSetAdoptedDelta :: UTCTime -> Int -> MachBlockEvents -> MachBlockEvents
mbeSetAdoptedDelta   v d = either (\x -> Left x { boeAdopted=Just v, boeChainDelta=d })   (\x -> Right x { bfeAdopted=Just v, bfeChainDelta=d })

mbeSetAnnounced, mbeSetSent :: UTCTime -> MachBlockEvents -> MachBlockEvents
mbeSetAnnounced v = either (\x -> Left x { boeAnnounced=Just v }) (\x -> Right x { bfeAnnounced=Just v })
mbeSetSent      v = either (\x -> Left x { boeSent=Just v })      (\x -> Right x { bfeSent=Just v })

-- | Machine's private view of all the blocks.
type MachBlockMap
  =  Map.Map Hash MachBlockEvents

blockMapHost :: MachBlockMap -> Host
blockMapHost = either boeHost bfeHost . head . Map.elems

blockMapMaxBlock :: MachBlockMap -> MachBlockEvents
blockMapMaxBlock = maximumBy ordBlockEv . Map.elems

blockMapBlock :: Hash -> MachBlockMap -> MachBlockEvents
blockMapBlock h =
  fromMaybe (error $ "Invariant failed:  missing hash " <> show h) . Map.lookup h

-- | A completed, compactified version of BlockObserverEvents.
data BlockObservation
  =  BlockObservation
  { boObserver   :: !Host
  , boNoticed    :: !UTCTime
  , boFetched    :: !UTCTime
  , boAdopted    :: !(Maybe UTCTime)
  , boChainDelta :: !Int -- ^ ChainDelta during adoption
  , boAnnounced  :: !(Maybe UTCTime)
  , boSent       :: !(Maybe UTCTime)
  }
  deriving (Generic, AE.FromJSON, AE.ToJSON)

-- | All events related to a block.
data BlockEvents
  =  BlockEvents
  { beForger       :: !Host
  , beBlock        :: !Hash
  , beBlockPrev    :: !Hash
  , beBlockNo      :: !BlockNo
  , beSlotNo       :: !SlotNo
  , beSlotStart    :: !UTCTime
  , beForged       :: !UTCTime
  , beAdopted      :: !UTCTime
  , beChainDelta   :: !Int -- ^ ChainDelta during adoption
  , beAnnounced    :: !UTCTime
  , beSent         :: !UTCTime
  , beObservations :: [BlockObservation]
  }
  deriving (Generic, AE.FromJSON, AE.ToJSON)

-- | Ordered list of all block events of a chain.
type ChainBlockEvents
  =  [BlockEvents]

mapChainToForgerEventCDF ::
     [PercSpec Float]
  -> ChainBlockEvents
  -> (BlockEvents -> Maybe UTCTime)
  -> Distribution Float NominalDiffTime
mapChainToForgerEventCDF percs cbe proj =
  computeDistribution percs (mapMaybe blockDelta cbe)
 where
   blockDelta :: BlockEvents -> Maybe NominalDiffTime
   blockDelta be = (`Time.diffUTCTime` beSlotStart be) <$> proj be

mapChainToPeerBlockObservationCDFs ::
     [PercSpec Float]
  -> ChainBlockEvents
  -> (BlockObservation -> Maybe UTCTime)
  -> (Distribution Float NominalDiffTime, Distribution Float NominalDiffTime)
mapChainToPeerBlockObservationCDFs percs cbe proj =
  (means, covs)
 where
   means, covs :: Distribution Float NominalDiffTime
   (,) means covs = computeDistributionStats (fmap realToFrac <$> allDistributions)
                    & either error id
                    & join (***) (fmap realToFrac)

   allDistributions :: [Distribution Float NominalDiffTime]
   allDistributions = computeDistribution percs <$> allObservations

   allObservations :: [[NominalDiffTime]]
   allObservations = mapMaybe blockObservations cbe

   blockObservations :: BlockEvents -> Maybe [NominalDiffTime]
   blockObservations be =
     fmap (`Time.diffUTCTime` beSlotStart be) <$> mapM proj (beObservations be)

blockProp :: ChainInfo -> [(JsonLogfile, [LogObject])] -> IO BlockPropagation
blockProp ci xs = do
  putStrLn ("blockProp: recovering block event maps" :: String)
  doBlockProp =<< mapConcurrently (pure . blockEventsFromLogObjects ci) xs

doBlockProp :: [MachBlockMap] -> IO BlockPropagation
doBlockProp eventMaps = do
  putStrLn ("tip block: " <> show tipBlock :: String)
  putStrLn ("chain length: " <> show (length chain) :: String)
  pure $ BlockPropagation
    (forgerEventsCDF    (Just . beForged))
    (forgerEventsCDF    (\x -> if beChainDelta x == 1 then Just (beAdopted x)
                               else Nothing))
    (forgerEventsCDF    (Just . beAnnounced))
    (forgerEventsCDF    (Just . beSent))
    (observerEventsCDFs (Just . boNoticed))
    (observerEventsCDFs (Just . boFetched))
    (observerEventsCDFs (\x -> if boChainDelta x == 1 then boAdopted x
                               else Nothing))
    (observerEventsCDFs boAnnounced)
    (observerEventsCDFs boSent)
 where
   forgerEventsCDF    = mapChainToForgerEventCDF           stdPercentiles chain
   observerEventsCDFs = mapChainToPeerBlockObservationCDFs stdPercentiles chain

   chain          = rebuildChain eventMaps tipHash
   tipBlock       = getBlockForge eventMaps tipHash
   tipHash        = rewindChain eventMaps 1 (mbeBlockHash finalBlockEv)
   finalBlockEv   = maximumBy ordBlockEv $ blockMapMaxBlock <$> eventMaps

   rewindChain :: [MachBlockMap] -> Int -> Hash -> Hash
   rewindChain eventMaps count tip = go tip count
    where go tip = \case
            0 -> tip
            n -> go (bfeBlockPrev $ getBlockForge eventMaps tip) (n - 1)

   getBlockForge :: [MachBlockMap] -> Hash -> BlockForgerEvents
   getBlockForge xs h =
     either (error "Invariant failed: finalBlockEv isn't a forge.") id $
            maximumBy ordBlockEv $
            mapMaybe (Map.lookup h) xs

   rebuildChain :: [MachBlockMap] -> Hash -> ChainBlockEvents
   rebuildChain machBlockMaps tip = go (Just tip) []
    where go Nothing  acc = acc
          go (Just h) acc =
            let blkEvs@(forgerEv, _) = collectAllBlockEvents machBlockMaps h
            in go (bfePrevBlock forgerEv)
                  (liftBlockEvents blkEvs : acc)

   collectAllBlockEvents :: [MachBlockMap] -> Hash -> (BlockForgerEvents, [BlockObserverEvents])
   collectAllBlockEvents xs blk =
     partitionEithers (mapMaybe (Map.lookup blk) xs)
     & swap & (head *** id)

   liftBlockEvents :: (BlockForgerEvents, [BlockObserverEvents]) -> BlockEvents
   liftBlockEvents (BlockForgerEvents{..}, os) =
     BlockEvents
     { beForger     = bfeHost
     , beBlock      = bfeBlock
     , beBlockPrev  = bfeBlockPrev
     , beBlockNo    = bfeBlockNo
     , beSlotNo     = bfeSlotNo
     , beSlotStart  = bfeSlotStart
     , beForged     = bfeForged    & miss "Forged"
     , beAdopted    = bfeAdopted   & miss "Adopted (forger)"
     , beChainDelta = bfeChainDelta
     , beAnnounced  = bfeAnnounced & miss "Announced (forger)"
     , beSent       = bfeSent      & miss "Sent (forger)"
     , beObservations = catMaybes $
       os <&> \BlockObserverEvents{..}->
         BlockObservation
           <$> Just boeHost
           <*> boeNoticed
           <*> boeFetched
           <*> Just boeAdopted
           <*> Just boeChainDelta
           <*> Just boeAnnounced
           <*> Just boeSent
     }
    where
      miss :: String -> Maybe a -> a
      miss slotDesc = fromMaybe $ error $ mconcat
       [ "While processing ", show bfeBlockNo, " hash ", show bfeBlock
       , " forged by ", show bfeHost
       , " -- missing slot: ", slotDesc
       ]

-- | Given a single machine's log object stream, recover its block map.
blockEventsFromLogObjects :: ChainInfo -> (JsonLogfile, [LogObject]) -> MachBlockMap
blockEventsFromLogObjects ci (fp, xs) =
  foldl (blockPropMachEventsStep ci fp) mempty xs

blockPropMachEventsStep :: ChainInfo -> JsonLogfile -> MachBlockMap -> LogObject -> MachBlockMap
blockPropMachEventsStep ci fp bMap = \case
  LogObject{loAt, loHost, loBody=LOBlockForged{loBlock,loPrev,loBlockNo,loSlotNo}} ->
    flip (Map.insert loBlock) bMap $
    Right (mbmGetForger loHost loBlock bMap "LOBlockForged"
           & fromMaybe (mbe0forger loHost loBlock loPrev loBlockNo loSlotNo))
          { bfeForged = Just loAt }
  LogObject{loAt, loHost, loBody=LOBlockAddedToCurrentChain{loBlock,loChainLengthDelta}} ->
    let mbe0 = Map.lookup loBlock bMap & fromMaybe
               (err loHost loBlock "LOBlockAddedToCurrentChain leads")
    in Map.insert loBlock (mbeSetAdoptedDelta loAt loChainLengthDelta mbe0) bMap
  LogObject{loAt, loHost, loBody=LOChainSyncServerSendHeader{loBlock}} ->
    let mbe0 = Map.lookup loBlock bMap & fromMaybe
               (err loHost loBlock "LOChainSyncServerSendHeader leads")
    in Map.insert loBlock (mbeSetAnnounced loAt mbe0) bMap
  LogObject{loAt, loHost, loBody=LOBlockFetchServerSend{loBlock}} ->
    -- D.trace (D.printf "mbeSetSent %s %s" (show loHost :: String) (show loBlock :: String)) $
    let mbe0 = Map.lookup loBlock bMap & fromMaybe
               (err loHost loBlock "LOBlockFetchServerSend leads")
    in Map.insert loBlock (mbeSetSent loAt mbe0) bMap
  LogObject{loAt, loHost, loBody=LOChainSyncClientSeenHeader{loBlock,loBlockNo,loSlotNo}} ->
    case Map.lookup loBlock bMap of
      -- We only record the first ChainSync observation of a block.
      Nothing -> Map.insert loBlock
                 (Left $
                  (mbe0observ loHost loBlock loBlockNo loSlotNo)
                  { boeNoticed = Just loAt })
                 bMap
      Just{}  -> bMap
  LogObject{loAt, loHost, loBody=LOBlockFetchClientCompletedFetch{loBlock}} ->
    flip (Map.insert loBlock) bMap $
    Left (mbmGetObserver loHost loBlock bMap  "LOBlockFetchClientCompletedFetch")
         { boeFetched = Just loAt }
  _ -> bMap
 where
   err :: Host -> Hash -> String -> a
   err ho ha desc = error $ mconcat
     [ "In file ", show fp
     , ", for host ", show ho
     , ", for block ", show ha
     , ": ", desc
     ]
   mbe0observ :: Host -> Hash -> BlockNo -> SlotNo -> BlockObserverEvents
   mbe0observ ho ha bn sn =
     BlockObserverEvents ho ha bn sn (slotStart ci sn)
     Nothing Nothing Nothing 0 Nothing Nothing
   mbe0forger :: Host -> Hash -> Hash -> BlockNo -> SlotNo -> BlockForgerEvents
   mbe0forger ho ha hp bn sn =
     BlockForgerEvents ho ha hp bn sn (slotStart ci sn)
     Nothing Nothing 0 Nothing Nothing
   mbmGetObserver :: Host -> Hash -> MachBlockMap -> String -> BlockObserverEvents
   mbmGetObserver ho ha m eDesc = case Map.lookup ha m of
     Just (Left x) -> x
     Just (Right x) -> err ho ha (eDesc <> " after a BlockForgerEvents")
     Nothing ->  err ho ha (eDesc <> " leads")
   mbmGetForger :: Host -> Hash -> MachBlockMap -> String -> Maybe BlockForgerEvents
   mbmGetForger ho ha m eDesc = Map.lookup ha m <&>
     either (const $ err ho ha (eDesc <> " after a BlockObserverEvents")) id
