{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module System.Metrics.Prometheus.Wai.Middleware
  ( registerWaiMetrics,
    WaiMetrics (..),
    instrumentWaiMiddleware,
    metricsEndpointMiddleware,
    metricsEndpointAtMiddleware,
    metricsEndpointAtMiddlewareWithHook,
  )
where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import qualified Network.HTTP.Types as HTTP
import Network.Wai as Wai (Middleware)
import qualified Network.Wai as Request
import qualified Network.Wai as Wai
import System.Metrics.Prometheus.Concurrent.Registry (Registry)
import qualified System.Metrics.Prometheus.Concurrent.Registry as Prometheus
import qualified System.Metrics.Prometheus.Concurrent.Registry as Registry
import qualified System.Metrics.Prometheus.Encode.Text as Prometheus
import qualified System.Metrics.Prometheus.Metric.Counter as Counter (inc)
import qualified System.Metrics.Prometheus.Metric.Counter as Prometheus (Counter)
import qualified System.Metrics.Prometheus.Metric.Histogram as Histogram (observe)
import qualified System.Metrics.Prometheus.Metric.Histogram as Prometheus (Histogram)
import qualified System.Metrics.Prometheus.MetricId as Labels
import qualified System.Metrics.Prometheus.MetricId as Prometheus (Labels (..))

data WaiMetrics = WaiMetrics
  { waiMetricsStatusCode :: !(Map Int Prometheus.Counter),
    waiMetricsDuration :: !Prometheus.Histogram
  }

-- | Register the Wai metrics with the given labels at the given registry.
registerWaiMetrics :: Prometheus.Labels -> Registry -> IO WaiMetrics
registerWaiMetrics labels registry = do
  -- Status code counters
  -- Based on the codes defined at
  -- https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status
  let codes =
        [100 .. 103]
          <> [200 .. 208]
          <> [226]
          <> [300 .. 304]
          <> [307, 308]
          <> [400 .. 418]
          <> [421 .. 426]
          <> [428, 429, 431, 451]
          <> [500 .. 508]
          <> [510, 511]
  let labelsForCode code = Labels.addLabel "http_response_code" (T.pack (show code)) labels
  waiMetricsStatusCode <- fmap M.fromList $ forM codes $ \code -> do
    counterForCode <- Prometheus.registerCounter "http_requests_total" (labelsForCode code) registry
    pure (code, counterForCode)

  -- Duration histogram
  let durationBounds =
        concat
          [ [1, 2, 3, 5],
            [10, 20, 30, 40, 50],
            [100, 200, 300, 400, 500],
            [1_000, 2_000, 3_000, 4_000, 5_000],
            [10_000]
          ]
  waiMetricsDuration <- Prometheus.registerHistogram "http_request_duration_milliseconds" labels durationBounds registry
  pure WaiMetrics {..}

-- | Record the given Wai metrics in a middleware.
instrumentWaiMiddleware :: WaiMetrics -> Wai.Middleware
instrumentWaiMiddleware WaiMetrics {..} application request sendResponse =
  let isWebSocketsReq =
        lookup "upgrade" (Wai.requestHeaders request) == Just "websocket"
      shouldInstrument =
        -- Don't instrument WebSocket requests because they don't have a
        -- response but some libraries still pretend that it does and will
        -- give it a 500 status code.
        -- Moreover, the 'latency' will be 'how long the connection was open'
        -- which is also useless.
        not isWebSocketsReq
   in if shouldInstrument
        then do
          begin <- getMonotonicTimeNSec
          application request $ \response -> do
            end <- getMonotonicTimeNSec

            -- Count the status code
            mapM_ Counter.inc (M.lookup (HTTP.statusCode (Wai.responseStatus response)) waiMetricsStatusCode)

            -- Count the application response duration
            let nanos = end - begin
                millis = fromIntegral nanos / 1_000_000
            Histogram.observe millis waiMetricsDuration

            sendResponse response
        else application request sendResponse

-- | Add a metrics endpoint using the given registry.
metricsEndpointMiddleware :: Registry -> Wai.Middleware
metricsEndpointMiddleware = metricsEndpointAtMiddleware "/metrics"

-- | Add a metrics endpoint at a given path using the given registry.
metricsEndpointAtMiddleware :: ByteString -> Registry -> Wai.Middleware
metricsEndpointAtMiddleware =
  metricsEndpointAtMiddlewareWithHook (pure ())

-- | Add a metrics endpoint at a given path and last-minute hook using the given registry.
--
-- This lets you set metrics that are evaluated when the /metrics endpoint is hit.
metricsEndpointAtMiddlewareWithHook ::
  IO () ->
  ByteString ->
  Registry ->
  Wai.Middleware
metricsEndpointAtMiddlewareWithHook lastMinuteHook path registry application request sendResponse =
  if Request.rawPathInfo request == path
    then do
      lastMinuteHook
      s <- Registry.sample registry
      sendResponse
        $ Wai.responseBuilder
          HTTP.ok200
          [(HTTP.hContentType, "text/plain; version=0.0.4; charset=utf-8")]
        $ Prometheus.encodeMetrics s
    else application request sendResponse
