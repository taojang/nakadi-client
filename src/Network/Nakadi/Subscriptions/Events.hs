{-|
Module      : Network.Nakadi.Subscriptions.Events
Description : Implementation of Nakadi Subscription Events API
Copyright   : (c) Moritz Schulte 2017, 2018
License     : BSD3
Maintainer  : mtesseract@silverratio.net
Stability   : experimental
Portability : POSIX

This module implements a high level interface for the
@\/subscriptions\/SUBSCRIPTIONS\/events@ API.
-}

{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Network.Nakadi.Subscriptions.Events
  ( subscriptionProcessConduit
  , subscriptionProcess
  ) where

import           Network.Nakadi.Internal.Prelude

import           Conduit                              hiding (throwM)
import           Control.Concurrent.Async.Lifted      (link, withAsync)
import           Control.Concurrent.STM               (TBQueue, atomically,
                                                       newTBQueue, readTBQueue,
                                                       writeTBQueue)
import           Control.Lens
import           Data.Aeson
import qualified Data.Conduit.List                    as Conduit (map, mapM_)
import           Network.HTTP.Client                  (responseBody)
import           Network.HTTP.Simple
import           Network.HTTP.Types
import           Network.Nakadi.Internal.Config
import           Network.Nakadi.Internal.Conversions
import           Network.Nakadi.Internal.Http
import qualified Network.Nakadi.Internal.Lenses       as L
import           Network.Nakadi.Subscriptions.Cursors

-- | Consumes the specified subscription using the commit strategy
-- contained in the configuration. Each consumed batch of subscription
-- events is provided to the provided batch processor action. If this
-- action throws an exception, subscription consumtion will terminate.
subscriptionProcess
  :: ( MonadNakadi b m
     , MonadIO m
     , MonadBaseControl IO m
     , MonadMask m
     , FromJSON a )
  => Maybe ConsumeParameters
  -> SubscriptionId                           -- ^ Subscription to consume
  -> (SubscriptionEventStreamBatch a -> m ()) -- ^ Batch processor action
  -> m ()
subscriptionProcess maybeConsumeParameters subscriptionId processor =
  subscriptionProcessConduit maybeConsumeParameters subscriptionId conduit
  where conduit = iterMC processor

-- | Conduit based interface for subscription consumption. Consumes
-- the specified subscription using the commit strategy contained in
-- the configuration. Each consumed event batch is then processed by
-- the provided conduit. If an exception is thrown inside the conduit,
-- subscription consumtion will terminate.
subscriptionProcessConduit
  :: ( MonadNakadi b m
     , MonadIO m
     , MonadBaseControl IO m
     , MonadMask m
     , FromJSON a
     , L.HasNakadiSubscriptionCursor c )
  => Maybe ConsumeParameters
  -> SubscriptionId
  -> ConduitM (SubscriptionEventStreamBatch a) c m ()
  -> m ()
subscriptionProcessConduit maybeConsumeParameters subscriptionId processor = do
  config <- nakadiAsk
  let consumeParams = fromMaybe defaultConsumeParameters maybeConsumeParameters
      queryParams   = buildSubscriptionConsumeQueryParameters consumeParams
  httpJsonBodyStream ok200 [(status404, errorSubscriptionNotFound)]
    (includeFlowId config
     . setRequestPath path
     . setRequestQueryParameters queryParams) $
    subscriptionProcessHandler config subscriptionId processor

  where path = "/subscriptions/"
               <> subscriptionIdToByteString subscriptionId
               <> "/events"

-- | Derive a 'SubscriptionEventStream' from the provided
-- 'SubscriptionId' and Nakadi streaming response.
buildSubscriptionEventStream
  :: MonadThrow m
  => SubscriptionId
  -> Response a
  -> m SubscriptionEventStream
buildSubscriptionEventStream subscriptionId response =
  case listToMaybe (getResponseHeader "X-Nakadi-StreamId" response) of
    Just streamId ->
      pure SubscriptionEventStream
      { _streamId       = StreamId (decodeUtf8 streamId)
      , _subscriptionId = subscriptionId }
    Nothing ->
      throwM StreamIdMissing

subscriptionProcessHandler
  :: ( MonadThrow m
     , MonadIO m
     , MonadBaseControl IO m
     , MonadNakadi b m
     , FromJSON a
     , L.HasNakadiSubscriptionCursor c )
  => Config b
  -> SubscriptionId
  -> ConduitM (SubscriptionEventStreamBatch a) c m ()
  -> Response (ConduitM () ByteString m ())
  -> m ()
subscriptionProcessHandler config subscriptionId processor response = do
  eventStream <- buildSubscriptionEventStream subscriptionId response
  let producer = responseBody response
                 .| linesUnboundedAsciiC
                 .| conduitDecode config
                 .| processor
                 .| Conduit.map (view L.subscriptionCursor)
  case config^.L.commitStrategy of
    CommitSync ->
      runConduit $ producer .| subscriptionSink eventStream
    CommitAsync bufferingStrategy -> do
      queue <- liftIO . atomically $ newTBQueue 1024
      withAsync (subscriptionCommitter bufferingStrategy eventStream queue) $
        \ asyncHandle -> do
          link asyncHandle
          runConduit $
            producer
            .| Conduit.mapM_ (liftIO . atomically . writeTBQueue queue)

-- | Sink which can be used as sink for Conduits processing
-- subscriptions events. This sink takes care of committing events. It
-- can consume any values which contain Subscription Cursors.
subscriptionSink
  :: MonadNakadi b m
  => SubscriptionEventStream
  -> ConduitM SubscriptionCursor void m ()
subscriptionSink eventStream =
  awaitForever $ lift . subscriptionCursorCommit eventStream . (: [])

subscriptionCommitter
  :: (MonadIO m, MonadNakadi b m)
  => CommitBufferingStrategy
  -> SubscriptionEventStream
  -> TBQueue SubscriptionCursor
  -> m ()
subscriptionCommitter CommitNoBuffer eventStream queue = go
  where go = do
          a <- liftIO . atomically . readTBQueue $ queue
          subscriptionCursorCommit eventStream [a]
          go
