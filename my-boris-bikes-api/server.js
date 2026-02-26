const express = require("express");
const jwt = require("jsonwebtoken");
const fs = require("fs");
const path = require("path");
const http2 = require("http2");
const winston = require("winston");
const promClient = require("prom-client");
require("winston-daily-rotate-file");

// Configuration (override via environment variables)
const PORT = parseInt(process.env.PORT || "3010", 10);
const POLL_INTERVAL_MS = parseInt(
  process.env.POLL_INTERVAL_MS || "15000",
  10
);
const SESSION_TIMEOUT_MS = parseInt(
  process.env.SESSION_TIMEOUT_MS || "7200000",
  10
); // 2 hours
const MAX_NOTIFICATION_WINDOW_MS = parseInt(
  process.env.MAX_NOTIFICATION_WINDOW_MS || "7200000",
  10
); // hard cap for notification updates
const APNS_KEY_ID = process.env.APNS_KEY_ID || "UQ2DV6UTF4";
const APNS_TEAM_ID = process.env.APNS_TEAM_ID || "SJ8X4DLAN9";
const APNS_KEY_PATH =
  process.env.APNS_KEY_PATH ||
  path.join(__dirname, "certs", "APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8");
const APNS_TOPIC =
  process.env.APNS_TOPIC ||
  "dev.skynolimit.myborisbikes.My-Boris-Bikes.push-type.liveactivity";
// Regular app bundle-ID topic used for silent background pushes (not Live Activities)
const APNS_BACKGROUND_TOPIC =
  process.env.APNS_BACKGROUND_TOPIC_MY_BORIS_BIKES ||
  process.env.APNS_BACKGROUND_TOPIC ||
  (APNS_TOPIC.endsWith(".push-type.liveactivity")
    ? APNS_TOPIC.replace(/\.push-type\.liveactivity$/, "")
    : APNS_TOPIC);
// How often (ms) to send a silent background push to wake iOS for complication refresh
const COMPLICATION_REFRESH_INTERVAL_MS = parseInt(
  process.env.COMPLICATION_REFRESH_INTERVAL_MS || "60000",
  10
);
const DEFAULT_NOTIFICATION_WINDOW_MS = 2 * 60 * 60 * 1000;
const HARD_NOTIFICATION_CUTOFF_MS = 2 * 60 * 60 * 1000;
const EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS =
  Number.isFinite(MAX_NOTIFICATION_WINDOW_MS) && MAX_NOTIFICATION_WINDOW_MS > 0
    ? MAX_NOTIFICATION_WINDOW_MS
    : DEFAULT_NOTIFICATION_WINDOW_MS;
const TFL_API_BASE = "https://api.tfl.gov.uk";
const LOG_DIR = process.env.LOG_DIR || path.join(__dirname, "logs");
const COMPLICATION_TOKENS_PATH =
  process.env.COMPLICATION_TOKENS_PATH ||
  path.join(__dirname, "complication-tokens.json");
const DOCK_OVERRIDES_PATH =
  process.env.DOCK_OVERRIDES_PATH ||
  path.join(__dirname, "dock-overrides.json");
const MAX_LIVE_ACTIVITY_ALTERNATIVES = 5;
const VALID_PRIMARY_DISPLAYS = new Set(["bikes", "eBikes", "spaces"]);

// Ensure logs directory exists
if (!fs.existsSync(LOG_DIR)) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

// Configure Winston logger
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: winston.format.combine(
    winston.format.timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
    winston.format.errors({ stack: true }),
    winston.format.printf(
      ({ timestamp, level, message, stack }) =>
        `${timestamp} [${level.toUpperCase()}] ${stack || message}`
    )
  ),
  transports: [
    // Console output
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.printf(
          ({ timestamp, level, message }) => `${timestamp} [${level}] ${message}`
        )
      ),
    }),
    // Daily rotating file for all logs
    new winston.transports.DailyRotateFile({
      filename: path.join(LOG_DIR, "server-%DATE%.log"),
      datePattern: "YYYY-MM-DD",
      maxSize: "20m",
      maxFiles: "3d", // Keep logs for 3 days
      zippedArchive: false,
    }),
    // Separate file for errors only
    new winston.transports.DailyRotateFile({
      filename: path.join(LOG_DIR, "error-%DATE%.log"),
      datePattern: "YYYY-MM-DD",
      level: "error",
      maxSize: "20m",
      maxFiles: "7d", // Keep error logs for 7 days
      zippedArchive: false,
    }),
  ],
});

// Load APNS private key
let apnsKey;
try {
  apnsKey = fs.readFileSync(APNS_KEY_PATH, "utf8");
  logger.info("APNS key loaded successfully");
} catch (err) {
  logger.error(`Failed to load APNS key from ${APNS_KEY_PATH}: ${err.message}`);
  process.exit(1);
}

// APNS JWT token cache
let cachedJwt = null;
let cachedJwtExpiry = 0;

function getApnsJwt() {
  const now = Math.floor(Date.now() / 1000);
  // Regenerate if expired or within 5 minutes of expiry
  if (cachedJwt && cachedJwtExpiry - now > 300) {
    return cachedJwt;
  }
  const payload = {
    iss: APNS_TEAM_ID,
    iat: now,
  };
  cachedJwt = jwt.sign(payload, apnsKey, {
    algorithm: "ES256",
    header: { alg: "ES256", kid: APNS_KEY_ID },
  });
  cachedJwtExpiry = now + 3600; // 1 hour
  logger.info("Generated new APNS JWT token");
  return cachedJwt;
}

// ── Prometheus Metrics ───────────────────────────────────────────────
const register = new promClient.Registry();

// Default metrics (CPU, memory, etc.)
promClient.collectDefaultMetrics({ register });

// Device token tracking for unique users over time periods
const deviceTokens = {
  all: new Set(), // all-time
  "1m": new Map(), // timestamp -> Set of tokens
  "5m": new Map(),
  "1h": new Map(),
  "1d": new Map(),
  "1w": new Map(),
  "30d": new Map(),
};

// Clean up old device token entries
function cleanupDeviceTokens() {
  const now = Date.now();
  const periods = {
    "1m": 60 * 1000,
    "5m": 5 * 60 * 1000,
    "1h": 60 * 60 * 1000,
    "1d": 24 * 60 * 60 * 1000,
    "1w": 7 * 24 * 60 * 60 * 1000,
    "30d": 30 * 24 * 60 * 60 * 1000,
  };

  for (const [period, duration] of Object.entries(periods)) {
    if (period === "all") continue;
    const cutoff = now - duration;
    for (const [timestamp, _] of deviceTokens[period]) {
      if (timestamp < cutoff) {
        deviceTokens[period].delete(timestamp);
      }
    }
  }
}

// Track device token
function trackDeviceToken(deviceToken) {
  if (!deviceToken) return;

  deviceTokens.all.add(deviceToken);
  const now = Date.now();

  for (const period of ["1m", "5m", "1h", "1d", "1w", "30d"]) {
    if (!deviceTokens[period].has(now)) {
      deviceTokens[period].set(now, new Set());
    }
    deviceTokens[period].get(now).add(deviceToken);
  }
}

// Get unique user count for a period
function getUniqueUserCount(period) {
  if (period === "all") {
    return deviceTokens.all.size;
  }

  const uniqueTokens = new Set();
  for (const [_, tokens] of deviceTokens[period]) {
    for (const token of tokens) {
      uniqueTokens.add(token);
    }
  }
  return uniqueTokens.size;
}

// Run cleanup every minute
setInterval(cleanupDeviceTokens, 60 * 1000);

// HTTP request metrics
const httpRequestDuration = new promClient.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5],
  registers: [register],
});

const httpRequestsTotal = new promClient.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// TfL API request metrics
const tflRequestDuration = new promClient.Histogram({
  name: "tfl_request_duration_seconds",
  help: "Duration of TfL API requests in seconds",
  labelNames: ["method", "url_path", "status_code"],
  buckets: [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10],
  registers: [register],
});

const tflRequestsTotal = new promClient.Counter({
  name: "tfl_requests_total",
  help: "Total number of TfL API requests",
  labelNames: ["method", "url_path", "status_code"],
  registers: [register],
});

// Live activity metrics
const liveActivitiesActive = new promClient.Gauge({
  name: "live_activities_active",
  help: "Number of currently active live activities",
  registers: [register],
});

const liveActivitiesTotal = new promClient.Counter({
  name: "live_activities_total",
  help: "Total number of live activities started",
  labelNames: ["build_type"],
  registers: [register],
});

const liveActivitiesEnded = new promClient.Counter({
  name: "live_activities_ended_total",
  help: "Total number of live activities ended",
  labelNames: ["reason"], // "user", "expired", "error"
  registers: [register],
});

const apnsPushesTotal = new promClient.Counter({
  name: "apns_pushes_total",
  help: "Total number of APNS pushes sent",
  labelNames: ["event", "build_type", "status"], // event: "update"/"end"/"availability_alert", status: "success"/"failure"
  registers: [register],
});

const dockPollsTotal = new promClient.Counter({
  name: "dock_polls_total",
  help: "Total number of dock polls",
  labelNames: ["dock_id", "status"], // status: "success"/"failure"
  registers: [register],
});

const appActionsTotal = new promClient.Counter({
  name: "app_actions_total",
  help: "Total number of app actions recorded",
  labelNames: ["action", "screen", "dock_id", "dock_name", "build_type"],
  registers: [register],
});

const dockStatsTrackedActions = new Set([
  "favorite_add",
  "dock_tap",
  "live_activity_start",
]);

const dockStatsTotal = new promClient.Counter({
  name: "dock_stats_total",
  help:
    "Total number of dock interactions for favorite adds, map taps, and live activity starts",
  labelNames: ["action", "screen", "dock_id", "dock_name", "build_type"],
  registers: [register],
});

function activeLiveActivityTokenCount() {
  return Array.from(dockPollers.values()).reduce(
    (sum, poller) => sum + poller.tokens.size,
    0
  );
}

function updateLiveActivitiesActiveGauge() {
  liveActivitiesActive.set(activeLiveActivityTokenCount());
}

// Unique users gauge
const uniqueUsersGauge = new promClient.Gauge({
  name: "unique_users",
  help: "Number of unique users (by device token) over time periods",
  labelNames: ["period"], // "1m", "5m", "1h", "1d", "1w", "30d", "all"
  registers: [register],
  collect() {
    // Update gauges with current values
    for (const period of ["1m", "5m", "1h", "1d", "1w", "30d", "all"]) {
      this.set({ period }, getUniqueUserCount(period));
    }
  },
});

// ── Active Sessions ──────────────────────────────────────────────────
// dockPollers: Map<dockId, { interval, lastData, tokens: Map<pushToken, { buildType, startedAt, hardStopAt, expiryMs, alternatives, primaryDisplay, minimumThresholds, deviceToken, dockName }> }>
const dockPollers = new Map();

// ── Dock Value Overrides ─────────────────────────────────────────────
// Map<dockId, { standardBikes: number, eBikes: number, emptySpaces: number, updatedAt: number }>
const dockOverrides = new Map();

function loadDockOverrides() {
  try {
    if (!fs.existsSync(DOCK_OVERRIDES_PATH)) return;
    const raw = fs.readFileSync(DOCK_OVERRIDES_PATH, "utf8");
    const entries = JSON.parse(raw);
    for (const [dockId, override] of entries) {
      if (!dockId || typeof override !== "object" || !override) continue;
      dockOverrides.set(dockId, {
        standardBikes: Math.max(0, Math.trunc(Number(override.standardBikes) || 0)),
        eBikes: Math.max(0, Math.trunc(Number(override.eBikes) || 0)),
        emptySpaces: Math.max(0, Math.trunc(Number(override.emptySpaces) || 0)),
        updatedAt:
          Number.isFinite(override.updatedAt) && override.updatedAt > 0
            ? Math.trunc(override.updatedAt)
            : Date.now(),
      });
    }
    logger.info(`Loaded ${dockOverrides.size} dock override(s) from disk`);
  } catch (err) {
    logger.warn(`Could not load dock overrides from disk: ${err.message}`);
  }
}

function saveDockOverrides() {
  try {
    const entries = Array.from(dockOverrides.entries());
    fs.writeFileSync(DOCK_OVERRIDES_PATH, JSON.stringify(entries, null, 2));
  } catch (err) {
    logger.warn(`Could not save dock overrides to disk: ${err.message}`);
  }
}

loadDockOverrides();

// ── Complication Refresh Tokens ───────────────────────────────────────
// Regular APNs device tokens registered to receive silent background refresh pushes.
// Map<deviceToken, { buildType: 'development'|'production', registeredAt: number }>
const complicationTokens = new Map();

function loadComplicationTokens() {
  try {
    if (!fs.existsSync(COMPLICATION_TOKENS_PATH)) return;
    const raw = fs.readFileSync(COMPLICATION_TOKENS_PATH, "utf8");
    const entries = JSON.parse(raw);
    for (const [token, meta] of entries) {
      complicationTokens.set(token, meta);
    }
    logger.info(
      `Loaded ${complicationTokens.size} complication token(s) from disk`
    );
  } catch (err) {
    logger.warn(`Could not load complication tokens from disk: ${err.message}`);
  }
}

function saveComplicationTokens() {
  try {
    const entries = Array.from(complicationTokens.entries());
    fs.writeFileSync(COMPLICATION_TOKENS_PATH, JSON.stringify(entries, null, 2));
  } catch (err) {
    logger.warn(`Could not save complication tokens to disk: ${err.message}`);
  }
}

loadComplicationTokens();

const complicationPushesTotal = new promClient.Counter({
  name: "complication_pushes_total",
  help: "Total number of silent background pushes sent for complication refresh",
  labelNames: ["build_type", "status"],
  registers: [register],
});

const complicationTokensGauge = new promClient.Gauge({
  name: "complication_tokens_registered",
  help: "Number of device tokens currently registered for complication refresh",
  registers: [register],
  collect() {
    this.set(complicationTokens.size);
  },
});

// ── TfL API ──────────────────────────────────────────────────────────
async function fetchTflJson(urlPath, queryParams = {}, options = {}) {
  const { dockIdForPolling = null } = options;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(queryParams || {})) {
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) {
      for (const item of value) {
        params.append(key, String(item));
      }
    } else {
      params.set(key, String(value));
    }
  }

  const queryString = params.toString();
  const url = `${TFL_API_BASE}${urlPath}${queryString ? `?${queryString}` : ""}`;
  const method = "GET";
  const start = Date.now();

  let res;
  try {
    res = await fetch(url);
  } catch (err) {
    const duration = (Date.now() - start) / 1000;
    tflRequestDuration.observe(
      { method, url_path: urlPath, status_code: "error" },
      duration
    );
    tflRequestsTotal.inc({
      method,
      url_path: urlPath,
      status_code: "error",
    });
    if (dockIdForPolling) {
      dockPollsTotal.inc({ dock_id: dockIdForPolling, status: "failure" });
    }
    throw err;
  }

  const statusCode = res.status ? res.status.toString() : "unknown";
  const duration = (Date.now() - start) / 1000;
  tflRequestDuration.observe(
    { method, url_path: urlPath, status_code: statusCode },
    duration
  );
  tflRequestsTotal.inc({
    method,
    url_path: urlPath,
    status_code: statusCode,
  });

  if (!res.ok) {
    if (dockIdForPolling) {
      dockPollsTotal.inc({ dock_id: dockIdForPolling, status: "failure" });
    }
    throw new Error(`TfL API returned ${res.status} for ${urlPath}`);
  }

  try {
    const data = await res.json();
    if (dockIdForPolling) {
      dockPollsTotal.inc({ dock_id: dockIdForPolling, status: "success" });
    }
    return data;
  } catch (err) {
    if (dockIdForPolling) {
      dockPollsTotal.inc({ dock_id: dockIdForPolling, status: "failure" });
    }
    throw err;
  }
}

async function fetchDockData(dockId) {
  const bikePoint = await fetchTflJson(
    `/Place/${dockId}`,
    { cb: Date.now() },
    { dockIdForPolling: dockId }
  );
  return effectiveDockDataForDock(dockId, bikePoint);
}

function parseBikePointData(data) {
  const props = data?.additionalProperties || [];
  const getProp = (key) => {
    const prop = props.find((p) => p.key === key);
    return prop ? parseInt(prop.value, 10) || 0 : 0;
  };
  return {
    dockName:
      typeof data?.commonName === "string" && data.commonName.trim()
        ? data.commonName.trim()
        : null,
    standardBikes: getProp("NbStandardBikes"),
    eBikes: getProp("NbEBikes"),
    emptySpaces: getProp("NbEmptyDocks"),
  };
}

function effectiveDockDataForDock(dockId, bikePointData) {
  const parsed = parseBikePointData(bikePointData);
  const override = dockOverrides.get(dockId);
  if (!override) {
    return {
      dockName: parsed.dockName || dockId,
      standardBikes: parsed.standardBikes,
      eBikes: parsed.eBikes,
      emptySpaces: parsed.emptySpaces,
    };
  }

  return {
    dockName: parsed.dockName || dockId,
    standardBikes: override.standardBikes,
    eBikes: override.eBikes,
    emptySpaces: override.emptySpaces,
  };
}

function setAdditionalPropertyValue(additionalProperties, key, value) {
  const next = Array.isArray(additionalProperties) ? [...additionalProperties] : [];
  const normalizedValue = String(Math.max(0, Math.trunc(Number(value) || 0)));
  const existingIndex = next.findIndex((prop) => prop && prop.key === key);
  if (existingIndex >= 0) {
    next[existingIndex] = { ...next[existingIndex], value: normalizedValue };
  } else {
    next.push({ key, value: normalizedValue });
  }
  return next;
}

function applyOverrideToBikePoint(bikePoint) {
  if (!bikePoint || typeof bikePoint !== "object") return bikePoint;
  const override = dockOverrides.get(bikePoint.id);
  if (!override) return bikePoint;

  let additionalProperties = bikePoint.additionalProperties;
  additionalProperties = setAdditionalPropertyValue(
    additionalProperties,
    "NbStandardBikes",
    override.standardBikes
  );
  additionalProperties = setAdditionalPropertyValue(
    additionalProperties,
    "NbEBikes",
    override.eBikes
  );
  additionalProperties = setAdditionalPropertyValue(
    additionalProperties,
    "NbEmptyDocks",
    override.emptySpaces
  );

  return {
    ...bikePoint,
    additionalProperties,
  };
}

function sanitizePrimaryDisplay(rawValue) {
  return VALID_PRIMARY_DISPLAYS.has(rawValue) ? rawValue : "bikes";
}

function normalizeApnsDeviceToken(rawValue) {
  if (typeof rawValue !== "string") return null;
  const trimmed = rawValue.trim();
  if (!trimmed) return null;
  // APNs device tokens are hex-encoded bytes (typically 64 chars).
  if (!/^[a-fA-F0-9]{64,}$/.test(trimmed)) return null;
  return trimmed.toLowerCase();
}

function sanitizeThresholdValue(rawValue) {
  const parsedValue = Number(rawValue);
  if (!Number.isFinite(parsedValue)) return 0;
  return Math.max(0, Math.trunc(parsedValue));
}

function sanitizeMinimumThresholds(rawThresholds) {
  if (!rawThresholds || typeof rawThresholds !== "object") {
    return null;
  }

  return {
    bikes: sanitizeThresholdValue(rawThresholds.bikes),
    eBikes: sanitizeThresholdValue(rawThresholds.eBikes),
    spaces: sanitizeThresholdValue(rawThresholds.spaces),
  };
}

function sanitizeDockName(rawDockName) {
  if (typeof rawDockName !== "string") return null;
  const trimmed = rawDockName.trim();
  return trimmed || null;
}

function resolveSessionExpiryMs(expirySeconds) {
  const parsedExpirySeconds = Number(expirySeconds);
  const defaultExpiryMs = Math.min(
    SESSION_TIMEOUT_MS,
    EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS,
    HARD_NOTIFICATION_CUTOFF_MS
  );
  const requestedExpiryMs =
    Number.isFinite(parsedExpirySeconds) && parsedExpirySeconds > 0
      ? parsedExpirySeconds * 1000
      : defaultExpiryMs;
  return Math.min(
    requestedExpiryMs,
    EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS,
    HARD_NOTIFICATION_CUTOFF_MS
  );
}

function sessionTimeoutMs(session) {
  const parsedExpiryMs = Number(session?.expiryMs);
  const fallbackExpiryMs = Math.min(
    SESSION_TIMEOUT_MS,
    EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS,
    HARD_NOTIFICATION_CUTOFF_MS
  );
  const requestedExpiryMs =
    Number.isFinite(parsedExpiryMs) && parsedExpiryMs > 0
      ? parsedExpiryMs
      : fallbackExpiryMs;

  return Math.min(
    requestedExpiryMs,
    EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS,
    HARD_NOTIFICATION_CUTOFF_MS
  );
}

function sessionStartedAtMs(session) {
  const startedAt = Number(session?.startedAt);
  return Number.isFinite(startedAt) && startedAt > 0 ? startedAt : Date.now();
}

function sessionHardStopAtMs(session) {
  const startedAt = sessionStartedAtMs(session);
  const requestedHardStopAt = Number(session?.hardStopAt);
  const cappedHardStopAt = startedAt + HARD_NOTIFICATION_CUTOFF_MS;
  if (!Number.isFinite(requestedHardStopAt) || requestedHardStopAt <= 0) {
    return cappedHardStopAt;
  }
  return Math.min(requestedHardStopAt, cappedHardStopAt);
}

function sessionExpiresAtMs(session) {
  const startedAt = sessionStartedAtMs(session);
  const timeoutExpiryMs = startedAt + sessionTimeoutMs(session);
  return Math.min(timeoutExpiryMs, sessionHardStopAtMs(session));
}

function collectSessionsForDevice(deviceToken, buildType = null) {
  const now = Date.now();
  const matches = [];
  for (const [dockId, poller] of dockPollers) {
    for (const [pushToken, session] of poller.tokens) {
      if (session.deviceToken !== deviceToken) continue;
      if (buildType && session.buildType !== buildType) continue;
      const startedAt = sessionStartedAtMs(session);
      const expiresAtMs = sessionExpiresAtMs(session);
      if (expiresAtMs <= now) continue;
      const dockName =
        session.dockName ||
        (typeof poller.lastData?.dockName === "string" &&
        poller.lastData.dockName.trim()
          ? poller.lastData.dockName.trim()
          : dockId);

      matches.push({
        dockId,
        dockName,
        pushToken,
        buildType: session.buildType,
        startedAt,
        expiresAtMs,
      });
    }
  }

  return matches.sort((a, b) => b.startedAt - a.startedAt);
}

function primaryValueForDisplay(data, primaryDisplay) {
  switch (primaryDisplay) {
    case "eBikes":
      return data.eBikes;
    case "spaces":
      return data.emptySpaces;
    case "bikes":
    default:
      return data.standardBikes;
  }
}

function singularMetricLabel(primaryDisplay) {
  switch (primaryDisplay) {
    case "eBikes":
      return "e-bike";
    case "spaces":
      return "space";
    case "bikes":
    default:
      return "bike";
  }
}

function pluralMetricLabel(primaryDisplay) {
  switch (primaryDisplay) {
    case "eBikes":
      return "e-bikes";
    case "spaces":
      return "spaces";
    case "bikes":
    default:
      return "bikes";
  }
}

function metricLabelForValue(primaryDisplay, value) {
  return value === 1
    ? singularMetricLabel(primaryDisplay)
    : pluralMetricLabel(primaryDisplay);
}

function minimumThresholdForDisplay(minimumThresholds, primaryDisplay) {
  if (!minimumThresholds || typeof minimumThresholds !== "object") {
    return 0;
  }
  return sanitizeThresholdValue(minimumThresholds[primaryDisplay]);
}

function buildAvailabilityAlertMessage(
  dockName,
  primaryDisplay,
  previousValue,
  currentValue,
  minimumThreshold = 0
) {
  const safeDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "This dock";

  if (previousValue === currentValue) {
    return null;
  }

  const normalizedThreshold = sanitizeThresholdValue(minimumThreshold);
  if (normalizedThreshold > 0) {
    if (currentValue < normalizedThreshold) {
      const prefix = currentValue === 0 ? "‼️" : "⚠️";
      if (currentValue === 0) {
        return `${prefix} ${safeDockName} now has no ${pluralMetricLabel(primaryDisplay)} available`;
      }

      const metricLabel = metricLabelForValue(primaryDisplay, currentValue);
      const isIncreaseWhileBelowThreshold = currentValue > previousValue;
      const qualifier = isIncreaseWhileBelowThreshold ? "now has" : "only has";
      return `${prefix} ${safeDockName} ${qualifier} ${currentValue} ${metricLabel} available`;
    }
  }

  if (normalizedThreshold > 0 && previousValue < normalizedThreshold && currentValue >= normalizedThreshold) {
    const metricLabel = metricLabelForValue(primaryDisplay, currentValue);
    return `✅ ${safeDockName} now has ${currentValue} ${metricLabel} available`;
  }

  if (previousValue > 0 && currentValue === 0) {
    return `‼️ ${safeDockName} no longer has any ${pluralMetricLabel(primaryDisplay)}`;
  }

  if (previousValue === 0 && currentValue > 0) {
    const metricLabel = metricLabelForValue(primaryDisplay, currentValue);
    return `✅ ${safeDockName} now has ${currentValue} ${metricLabel} available`;
  }

  return null;
}

function sanitizeAlternatives(rawAlternatives) {
  if (!Array.isArray(rawAlternatives)) {
    return [];
  }

  return rawAlternatives
    .slice(0, MAX_LIVE_ACTIVITY_ALTERNATIVES)
    .map((alt) => {
      const name = typeof alt?.name === "string" ? alt.name.trim() : "";
      if (!name) {
        return null;
      }

      const standardBikes = Number.isFinite(alt?.standardBikes)
        ? Math.max(0, Math.trunc(alt.standardBikes))
        : 0;
      const eBikes = Number.isFinite(alt?.eBikes)
        ? Math.max(0, Math.trunc(alt.eBikes))
        : 0;
      const emptySpaces = Number.isFinite(alt?.emptySpaces)
        ? Math.max(0, Math.trunc(alt.emptySpaces))
        : 0;

      return { name, standardBikes, eBikes, emptySpaces };
    })
    .filter(Boolean);
}

function contentStateWithAlternatives(data, session) {
  return {
    standardBikes: data.standardBikes,
    eBikes: data.eBikes,
    emptySpaces: data.emptySpaces,
    alternatives: session?.alternatives || [],
  };
}

// ── APNS Push ────────────────────────────────────────────────────────
function getApnsHost(buildType) {
  return buildType === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
}

function sendApnsPush(pushToken, contentState, event, buildType) {
  return new Promise((resolve, reject) => {
    const host = getApnsHost(buildType);
    const token = getApnsJwt();

    const client = http2.connect(`https://${host}`);

    client.on("error", (err) => {
      logger.error(`APNS connection error (${host}):`, err.message);
      reject(err);
    });

    const aps = {
      timestamp: Math.floor(Date.now() / 1000),
      event: event,
      "content-state": contentState,
    };

    // For "end" events, add dismissal-date to immediately dismiss the activity
    if (event === "end") {
      aps["dismissal-date"] = Math.floor(Date.now() / 1000);
      logger.info(`Sending "end" push with dismissal-date to ${pushToken.substring(0, 8)}...`);
    }

    const payload = JSON.stringify({ aps });

    const headers = {
      ":method": "POST",
      ":path": `/3/device/${pushToken}`,
      authorization: `bearer ${token}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    };

    const req = client.request(headers);

    let responseData = "";
    let statusCode;

    req.on("response", (headers) => {
      statusCode = headers[":status"];
    });

    req.on("data", (chunk) => {
      responseData += chunk;
    });

    req.on("end", () => {
      client.close();
      if (statusCode === 200) {
        apnsPushesTotal.inc({ event, build_type: buildType, status: "success" });
        resolve({ status: statusCode });
      } else {
        apnsPushesTotal.inc({ event, build_type: buildType, status: "failure" });
        logger.error(
          `APNS push failed (${statusCode}): ${responseData} [token: ${pushToken.substring(0, 8)}...]`
        );
        reject(
          new Error(`APNS returned ${statusCode}: ${responseData}`)
        );
      }
    });

    req.on("error", (err) => {
      client.close();
      reject(err);
    });

    req.end(payload);
  });
}

function sendAvailabilityAlertPush(deviceToken, buildType, alertBody) {
  return new Promise((resolve, reject) => {
    const host = getApnsHost(buildType);
    const token = getApnsJwt();

    const client = http2.connect(`https://${host}`);

    client.on("error", (err) => {
      logger.error(`APNS alert push connection error (${host}):`, err.message);
      reject(err);
    });

    const payload = JSON.stringify({
      aps: {
        alert: {
          title: "Dock availability update",
          body: alertBody,
        },
        sound: "default",
      },
    });

    const headers = {
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${token}`,
      "apns-topic": APNS_BACKGROUND_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };

    const req = client.request(headers);
    let responseData = "";
    let statusCode;

    req.on("response", (hdrs) => {
      statusCode = hdrs[":status"];
    });

    req.on("data", (chunk) => {
      responseData += chunk;
    });

    req.on("end", () => {
      client.close();
      const event = "availability_alert";
      if (statusCode === 200) {
        apnsPushesTotal.inc({ event, build_type: buildType, status: "success" });
        resolve({ status: statusCode });
      } else {
        apnsPushesTotal.inc({ event, build_type: buildType, status: "failure" });
        logger.error(
          `Availability alert push failed (${statusCode}): ${responseData} [token: ${deviceToken.substring(0, 8)}...]`
        );
        reject(new Error(`APNS returned ${statusCode}: ${responseData}`));
      }
    });

    req.on("error", (err) => {
      client.close();
      reject(err);
    });

    req.end(payload);
  });
}

// ── Silent Background Push (complication refresh) ─────────────────────
// Sends a content-available:1 push to wake the iOS app so it can fetch
// fresh dock data and relay it to the watch via transferCurrentComplicationUserInfo.
// Background pushes MUST use apns-priority: 5 (not 10).
function sendBackgroundPush(deviceToken, buildType) {
  return new Promise((resolve, reject) => {
    const host = getApnsHost(buildType);
    const token = getApnsJwt();

    const client = http2.connect(`https://${host}`);
    client.on("error", (err) => {
      logger.error(`APNS background push connection error: ${err.message}`);
      reject(err);
    });

    const payload = JSON.stringify({ aps: { "content-available": 1 } });

    const headers = {
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${token}`,
      "apns-topic": APNS_BACKGROUND_TOPIC,
      "apns-push-type": "background",
      "apns-priority": "5",          // MUST be 5 for background pushes
      "apns-expiration": "0",        // Don't deliver stale wake-ups
      "content-type": "application/json",
    };

    const req = client.request(headers);
    let responseData = "";
    let statusCode;

    req.on("response", (hdrs) => { statusCode = hdrs[":status"]; });
    req.on("data", (chunk) => { responseData += chunk; });
    req.on("end", () => {
      client.close();
      if (statusCode === 200) {
        complicationPushesTotal.inc({ build_type: buildType, status: "success" });
        resolve({ status: statusCode });
      } else {
        complicationPushesTotal.inc({ build_type: buildType, status: "failure" });
        logger.error(
          `Background push failed (${statusCode}): ${responseData} [token: ${deviceToken.substring(0, 8)}...]`
        );
        reject(new Error(`APNS returned ${statusCode}: ${responseData}`));
      }
    });
    req.on("error", (err) => { client.close(); reject(err); });
    req.end(payload);
  });
}

// ── Complication Refresh Scheduler ────────────────────────────────────
// Fires a silent push to every registered device every COMPLICATION_REFRESH_INTERVAL_MS.
// The iOS app wakes, fetches fresh TfL data, writes to the shared app group, and calls
// transferCurrentComplicationUserInfo to push the data to the watch face.
let complicationPushCycle = 0;
setInterval(async () => {
  if (complicationTokens.size === 0) return;

  complicationPushCycle++;
  logger.info(
    `Complication push cycle #${complicationPushCycle}: waking ${complicationTokens.size} device(s)`
  );

  const staleTokens = [];

  await Promise.all(
    Array.from(complicationTokens.entries()).map(async ([deviceToken, { buildType }]) => {
      try {
        await sendBackgroundPush(deviceToken, buildType);
      } catch (err) {
        // Remove tokens that APNs has flagged as bad
        const body = err.message || "";
        if (body.includes("BadDeviceToken") || body.includes("Unregistered")) {
          staleTokens.push(deviceToken);
          logger.info(`Removing stale complication token: ${deviceToken.substring(0, 8)}...`);
        }
      }
    })
  );

  for (const token of staleTokens) complicationTokens.delete(token);
  if (staleTokens.length > 0) saveComplicationTokens();
}, COMPLICATION_REFRESH_INTERVAL_MS);

// ── Polling Logic ────────────────────────────────────────────────────
function startPollingForDock(dockId) {
  if (dockPollers.has(dockId) && dockPollers.get(dockId).interval) {
    return; // Already polling
  }

  const poller = dockPollers.get(dockId) || {
    interval: null,
    lastData: null,
    tokens: new Map(),
  };
  dockPollers.set(dockId, poller);

  logger.info(`Starting poll for dock ${dockId} (every ${POLL_INTERVAL_MS}ms)`);

  // Do an immediate first poll
  pollDock(dockId);

  poller.interval = setInterval(() => pollDock(dockId), POLL_INTERVAL_MS);
}

async function pollDock(dockId) {
  const poller = dockPollers.get(dockId);
  if (!poller || poller.tokens.size === 0) {
    stopPollingForDock(dockId);
    return;
  }

  // Check for expired sessions
  const now = Date.now();
  let expiredSessionRemoved = false;
  for (const [pushToken, session] of poller.tokens) {
    const startedAt = sessionStartedAtMs(session);
    const timeoutMs = sessionTimeoutMs(session);
    const expiresAtMs = sessionExpiresAtMs(session);
    const elapsedMs = now - startedAt;
    const remainingMs = expiresAtMs - now;

    // Debug log every poll to track time to expiry
    if (timeoutMs <= 120000) { // Only log for sessions with short expiry (<=2 minutes)
      logger.info(
        `Dock ${dockId}: ${Math.floor(remainingMs / 1000)}s remaining until expiry (${elapsedMs / 1000}s elapsed of ${timeoutMs / 1000}s)`
      );
    }

    if (now >= expiresAtMs) {
      logger.info(
        `Session expired for dock ${dockId}, token ${pushToken.substring(0, 8)}... (after ${Math.floor((expiresAtMs - startedAt) / 1000)}s)`
      );
      // Send end event before removing
      try {
        const lastData = poller.lastData || {
          standardBikes: 0,
          eBikes: 0,
          emptySpaces: 0,
        };
        const contentState = contentStateWithAlternatives(lastData, session);
        await sendApnsPush(pushToken, contentState, "end", session.buildType);
        logger.info(`Successfully sent "end" push to ${pushToken.substring(0, 8)}...`);
      } catch (err) {
        logger.error(`Failed to send end push on expiry:`, err.message);
      }
      poller.tokens.delete(pushToken);
      liveActivitiesEnded.inc({ reason: "expired" });
      expiredSessionRemoved = true;
    }
  }

  if (expiredSessionRemoved) {
    updateLiveActivitiesActiveGauge();
  }

  // If no tokens left after expiry check, stop polling
  if (poller.tokens.size === 0) {
    stopPollingForDock(dockId);
    return;
  }

  try {
    const data = await fetchDockData(dockId);
    const previousData = poller.lastData;
    const hasChanged =
      !previousData ||
      previousData.standardBikes !== data.standardBikes ||
      previousData.eBikes !== data.eBikes ||
      previousData.emptySpaces !== data.emptySpaces;

    if (hasChanged) {
      logger.info(
        `Dock ${dockId} changed: bikes=${data.standardBikes}, eBikes=${data.eBikes}, spaces=${data.emptySpaces}`
      );
      const availabilityAlertPromises = [];
      if (previousData) {
        const sentAlerts = new Set();
        for (const [pushToken, session] of poller.tokens) {
          const primaryDisplay = sanitizePrimaryDisplay(session.primaryDisplay);
          const previousValue = primaryValueForDisplay(previousData, primaryDisplay);
          const currentValue = primaryValueForDisplay(data, primaryDisplay);
          const minimumThreshold = minimumThresholdForDisplay(
            session.minimumThresholds,
            primaryDisplay
          );
          const alertMessage = buildAvailabilityAlertMessage(
            data.dockName,
            primaryDisplay,
            previousValue,
            currentValue,
            minimumThreshold
          );

          if (!alertMessage) continue;
          if (!session.deviceToken) {
            logger.info(
              `Skipped availability alert for ${pushToken.substring(0, 8)}... (no device token registered)`
            );
            continue;
          }

          const dedupeKey = `${session.deviceToken}:${primaryDisplay}:${alertMessage}`;
          if (sentAlerts.has(dedupeKey)) continue;
          sentAlerts.add(dedupeKey);

          availabilityAlertPromises.push(
            sendAvailabilityAlertPush(
              session.deviceToken,
              session.buildType,
              alertMessage
            ).catch((err) => {
              logger.error(
                `Failed to send availability alert to ${session.deviceToken.substring(0, 8)}...:`,
                err.message
              );
            })
          );
        }
      }

      // Send update to all registered live activity tokens for this dock
      const pushPromises = [];
      for (const [pushToken, session] of poller.tokens) {
        const contentState = contentStateWithAlternatives(data, session);
        pushPromises.push(
          sendApnsPush(pushToken, contentState, "update", session.buildType).catch(
            (err) => {
              logger.error(
                `Failed to push to ${pushToken.substring(0, 8)}...:`,
                err.message
              );
            }
          )
        );
      }

      poller.lastData = data;
      await Promise.all([...pushPromises, ...availabilityAlertPromises]);
    }
  } catch (err) {
    logger.error(`Failed to poll dock ${dockId}:`, err.message);
  }
}

function stopPollingForDock(dockId) {
  const poller = dockPollers.get(dockId);
  if (poller) {
    if (poller.interval) {
      clearInterval(poller.interval);
      poller.interval = null;
    }
    if (poller.tokens.size === 0) {
      dockPollers.delete(dockId);
      logger.info(`Stopped polling for dock ${dockId} (no active tokens)`);
    }
  }
}

// ── Express Server ───────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Metrics middleware
const ignoredMetricPaths = new Set([
  "/favicon.ico",
  "/metrics",
  "/healthcheck",
  "/status"
]);

app.use((req, res, next) => {
  if (ignoredMetricPaths.has(req.path)) {
    return next();
  }

  const start = Date.now();

  // Track device token if present in header
  const deviceToken = req.headers["x-device-token"];
  if (deviceToken) {
    trackDeviceToken(deviceToken);
  }

  res.on("finish", () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route ? req.route.path : req.path;
    const statusCode = res.statusCode.toString();

    httpRequestDuration.observe(
      { method: req.method, route, status_code: statusCode },
      duration
    );

    httpRequestsTotal.inc({
      method: req.method,
      route,
      status_code: statusCode
    });
  });

  next();
});

// Server startup time
const serverStartTime = Date.now();

// Helper function to format uptime
function formatUptime(ms) {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 0) {
    return `${days}d ${hours % 24}h ${minutes % 60}m`;
  } else if (hours > 0) {
    return `${hours}h ${minutes % 60}m ${seconds % 60}s`;
  } else if (minutes > 0) {
    return `${minutes}m ${seconds % 60}s`;
  } else {
    return `${seconds}s`;
  }
}

function normalizeNonNegativeInteger(value) {
  const numericValue = Number(value);
  if (!Number.isFinite(numericValue) || numericValue < 0) {
    return null;
  }
  return Math.trunc(numericValue);
}

function serializeDockOverrides() {
  return Array.from(dockOverrides.entries())
    .map(([dockId, override]) => ({
      dockId,
      standardBikes: override.standardBikes,
      eBikes: override.eBikes,
      emptySpaces: override.emptySpaces,
      updatedAt: new Date(override.updatedAt).toISOString(),
    }))
    .sort((a, b) => a.dockId.localeCompare(b.dockId));
}

function renderAdminOverridesPage() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Dock Override Admin</title>
  <style>
    :root {
      --bg: #f3f5f9;
      --panel: #ffffff;
      --text: #172130;
      --muted: #6c778a;
      --accent: #0066d6;
      --danger: #b42318;
      --line: #d7dde8;
      --ok-bg: #ecfdf3;
      --ok-text: #067647;
      --err-bg: #fef3f2;
      --err-text: #b42318;
    }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(150deg, var(--bg), #e6edf8);
      color: var(--text);
    }
    main {
      max-width: 980px;
      margin: 0 auto;
      padding: 24px 16px 40px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: 28px;
    }
    .muted {
      margin: 0 0 16px;
      color: var(--muted);
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 16px;
      box-shadow: 0 8px 24px rgba(16, 24, 40, 0.06);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
    }
    label {
      display: flex;
      flex-direction: column;
      gap: 6px;
      font-size: 13px;
      color: var(--muted);
    }
    input, select, button {
      border-radius: 10px;
      border: 1px solid var(--line);
      padding: 10px 12px;
      font-size: 14px;
      font-family: inherit;
    }
    input, select {
      background: #fff;
      color: var(--text);
    }
    button {
      cursor: pointer;
      font-weight: 600;
    }
    button.primary {
      background: var(--accent);
      color: #fff;
      border-color: var(--accent);
    }
    button.secondary {
      background: #fff;
      color: var(--text);
    }
    button.danger {
      background: #fff;
      color: var(--danger);
      border-color: #f4c7c4;
    }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 12px;
    }
    #status {
      margin-top: 10px;
      padding: 10px 12px;
      border-radius: 8px;
      display: none;
      font-size: 13px;
      white-space: pre-wrap;
    }
    #status.ok {
      display: block;
      background: var(--ok-bg);
      color: var(--ok-text);
      border: 1px solid #b7ebcd;
    }
    #status.error {
      display: block;
      background: var(--err-bg);
      color: var(--err-text);
      border: 1px solid #f7c4bf;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 14px;
      font-size: 14px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      text-align: left;
      padding: 10px 8px;
      vertical-align: top;
    }
    th {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    td.actions-cell {
      white-space: nowrap;
    }
    .small {
      color: var(--muted);
      font-size: 12px;
      margin-top: 6px;
    }
    @media (max-width: 720px) {
      table, tbody, tr, td, th {
        display: block;
      }
      th {
        display: none;
      }
      tr {
        border-bottom: 1px solid var(--line);
        padding: 10px 0;
      }
      td {
        border: 0;
        padding: 4px 0;
      }
    }
  </style>
</head>
<body>
  <main>
    <h1>Dock Override Admin</h1>
    <p class="muted">Set manual bikes/e-bikes/spaces values for a dock. Overrides affect <code>/Place/:dockId</code>, <code>/BikePoint</code>, and live activity polling.</p>

    <section class="panel">
      <div class="grid">
        <label>
          Search docks
          <input id="dockSearch" type="text" placeholder="Type part of a dock name or ID" />
        </label>
        <label style="grid-column: span 2;">
          Dock
          <select id="dockSelect"></select>
        </label>
        <label>
          Bikes
          <input id="standardBikes" type="number" min="0" step="1" value="0" />
        </label>
        <label>
          E-bikes
          <input id="eBikes" type="number" min="0" step="1" value="0" />
        </label>
        <label>
          Spaces
          <input id="emptySpaces" type="number" min="0" step="1" value="0" />
        </label>
      </div>
      <div class="actions">
        <button id="saveButton" class="primary">Save Override</button>
        <button id="clearButton" class="danger">Clear Selected Dock Override</button>
        <button id="refreshButton" class="secondary">Refresh</button>
      </div>
      <div id="status"></div>
      <div class="small" id="selectionHint"></div>
    </section>

    <section class="panel" style="margin-top: 14px;">
      <h2 style="margin: 0 0 4px; font-size: 18px;">Active Overrides</h2>
      <p class="muted" style="margin: 0 0 8px;">Use and clear overrides without leaving this page.</p>
      <table>
        <thead>
          <tr>
            <th>Dock</th>
            <th>Bikes</th>
            <th>E-bikes</th>
            <th>Spaces</th>
            <th>Updated</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody id="overridesBody"></tbody>
      </table>
    </section>
  </main>

  <script>
    const dockSearch = document.getElementById("dockSearch");
    const dockSelect = document.getElementById("dockSelect");
    const standardBikesInput = document.getElementById("standardBikes");
    const eBikesInput = document.getElementById("eBikes");
    const emptySpacesInput = document.getElementById("emptySpaces");
    const statusElement = document.getElementById("status");
    const selectionHint = document.getElementById("selectionHint");
    const overridesBody = document.getElementById("overridesBody");
    const normalizedPath = (window.location.pathname || "").replace(/\\/+$/, "");
    const adminBasePath = normalizedPath.endsWith("/admin") ? normalizedPath : "/admin";
    const apiBasePath = adminBasePath + "/api";

    let allDocks = [];
    let overridesByDockId = new Map();
    let filteredDocks = [];

    function apiUrl(path) {
      const suffix = path.startsWith("/") ? path : "/" + path;
      return apiBasePath + suffix;
    }

    function setStatus(message, type) {
      statusElement.className = type || "";
      statusElement.textContent = message || "";
      if (!message) {
        statusElement.style.display = "none";
      } else {
        statusElement.style.display = "block";
      }
    }

    function asInt(value) {
      const parsed = Number(value);
      if (!Number.isFinite(parsed) || parsed < 0) {
        return null;
      }
      return Math.trunc(parsed);
    }

    function selectedDockId() {
      const value = dockSelect.value || "";
      return value.trim();
    }

    function renderDockOptions() {
      const currentSelection = selectedDockId();
      dockSelect.innerHTML = "";

      if (filteredDocks.length === 0) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = "No docks match your search";
        dockSelect.appendChild(option);
        selectionHint.textContent = "";
        return;
      }

      for (const dock of filteredDocks) {
        const option = document.createElement("option");
        option.value = dock.id;
        option.textContent = dock.commonName + " (" + dock.id + ")";
        dockSelect.appendChild(option);
      }

      if (currentSelection && filteredDocks.some((dock) => dock.id === currentSelection)) {
        dockSelect.value = currentSelection;
      }
      syncFormToSelectedDock();
    }

    function applyDockFilter() {
      const query = (dockSearch.value || "").trim().toLowerCase();
      if (!query) {
        filteredDocks = [...allDocks];
      } else {
        filteredDocks = allDocks.filter((dock) =>
          dock.commonName.toLowerCase().includes(query) || dock.id.toLowerCase().includes(query)
        );
      }
      renderDockOptions();
    }

    function syncFormToSelectedDock() {
      const dockId = selectedDockId();
      if (!dockId) {
        selectionHint.textContent = "";
        return;
      }

      const selectedDock = allDocks.find((dock) => dock.id === dockId);
      const override = overridesByDockId.get(dockId);
      if (override) {
        standardBikesInput.value = String(override.standardBikes);
        eBikesInput.value = String(override.eBikes);
        emptySpacesInput.value = String(override.emptySpaces);
        selectionHint.textContent = "Editing override for " + selectedDock.commonName + ".";
      } else {
        standardBikesInput.value = "0";
        eBikesInput.value = "0";
        emptySpacesInput.value = "0";
        selectionHint.textContent = "No override set for " + selectedDock.commonName + ".";
      }
    }

    function renderOverridesTable() {
      const overrides = Array.from(overridesByDockId.values()).sort((a, b) =>
        a.dockId.localeCompare(b.dockId)
      );

      if (overrides.length === 0) {
        overridesBody.innerHTML = '<tr><td colspan="6">No active overrides.</td></tr>';
        return;
      }

      overridesBody.innerHTML = "";
      for (const override of overrides) {
        const dock = allDocks.find((item) => item.id === override.dockId);
        const dockLabel = dock
          ? dock.commonName + " (" + override.dockId + ")"
          : override.dockId;

        const row = document.createElement("tr");
        row.innerHTML =
          "<td>" + dockLabel + "</td>" +
          "<td>" + override.standardBikes + "</td>" +
          "<td>" + override.eBikes + "</td>" +
          "<td>" + override.emptySpaces + "</td>" +
          "<td>" + new Date(override.updatedAt).toLocaleString() + "</td>" +
          '<td class="actions-cell">' +
          '<button class="secondary" data-action="use" data-dock-id="' + override.dockId + '">Use</button> ' +
          '<button class="danger" data-action="clear" data-dock-id="' + override.dockId + '">Clear</button>' +
          "</td>";
        overridesBody.appendChild(row);
      }
    }

    async function loadDocks() {
      const response = await fetch(apiUrl("/docks"));
      if (!response.ok) {
        throw new Error("Could not load dock list");
      }
      const payload = await response.json();
      allDocks = payload.docks || [];
      filteredDocks = [...allDocks];
      renderDockOptions();
    }

    async function loadOverrides() {
      const response = await fetch(apiUrl("/overrides"));
      if (!response.ok) {
        throw new Error("Could not load overrides");
      }
      const payload = await response.json();
      overridesByDockId = new Map();
      for (const override of payload.overrides || []) {
        overridesByDockId.set(override.dockId, override);
      }
      renderOverridesTable();
      syncFormToSelectedDock();
    }

    async function saveOverride() {
      const dockId = selectedDockId();
      if (!dockId) {
        setStatus("Select a dock before saving.", "error");
        return;
      }

      const body = {
        dockId,
        standardBikes: asInt(standardBikesInput.value),
        eBikes: asInt(eBikesInput.value),
        emptySpaces: asInt(emptySpacesInput.value),
      };

      if (
        body.standardBikes === null ||
        body.eBikes === null ||
        body.emptySpaces === null
      ) {
        setStatus("All values must be whole numbers greater than or equal to 0.", "error");
        return;
      }

      const response = await fetch(apiUrl("/overrides"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const payload = await response.json();
      if (!response.ok) {
        setStatus(payload.error || "Failed to save override", "error");
        return;
      }

      setStatus("Saved override for " + payload.override.dockId + ".", "ok");
      await loadOverrides();
    }

    async function clearOverride(dockId) {
      const targetDockId = dockId || selectedDockId();
      if (!targetDockId) {
        setStatus("Select a dock before clearing.", "error");
        return;
      }

      const response = await fetch(
        apiUrl("/overrides/" + encodeURIComponent(targetDockId)),
        {
        method: "DELETE",
        }
      );
      const payload = await response.json();
      if (!response.ok) {
        setStatus(payload.error || "Failed to clear override", "error");
        return;
      }

      setStatus("Cleared override for " + targetDockId + ".", "ok");
      await loadOverrides();
    }

    document.getElementById("saveButton").addEventListener("click", () => {
      saveOverride().catch((err) => setStatus(err.message, "error"));
    });
    document.getElementById("clearButton").addEventListener("click", () => {
      clearOverride().catch((err) => setStatus(err.message, "error"));
    });
    document.getElementById("refreshButton").addEventListener("click", () => {
      Promise.all([loadDocks(), loadOverrides()])
        .then(() => setStatus("Reloaded dock list and overrides.", "ok"))
        .catch((err) => setStatus(err.message, "error"));
    });
    dockSearch.addEventListener("input", applyDockFilter);
    dockSelect.addEventListener("change", syncFormToSelectedDock);
    overridesBody.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-action]");
      if (!button) return;
      const action = button.getAttribute("data-action");
      const dockId = button.getAttribute("data-dock-id");
      if (!dockId) return;

      if (action === "use") {
        const dock = allDocks.find((item) => item.id === dockId);
        if (dock) {
          const query = dockSearch.value.trim().toLowerCase();
          if (query && !dock.commonName.toLowerCase().includes(query) && !dock.id.toLowerCase().includes(query)) {
            dockSearch.value = "";
            applyDockFilter();
          }
          dockSelect.value = dockId;
          syncFormToSelectedDock();
          setStatus("Loaded " + dock.commonName + " into the form.", "ok");
        }
        return;
      }

      if (action === "clear") {
        clearOverride(dockId).catch((err) => setStatus(err.message, "error"));
      }
    });

    Promise.all([loadDocks(), loadOverrides()])
      .then(() => setStatus("", ""))
      .catch((err) => setStatus(err.message, "error"));
  </script>
</body>
</html>`;
}

let dockListCache = {
  docks: [],
  fetchedAt: 0,
};
const DOCK_LIST_CACHE_MS = 5 * 60 * 1000;

async function fetchDockList() {
  const now = Date.now();
  if (
    dockListCache.docks.length > 0 &&
    now - dockListCache.fetchedAt < DOCK_LIST_CACHE_MS
  ) {
    return dockListCache.docks;
  }

  const bikePoints = await fetchTflJson("/BikePoint");
  const docks = Array.isArray(bikePoints)
    ? bikePoints
        .filter((point) => point && typeof point.id === "string")
        .map((point) => ({
          id: point.id,
          commonName:
            typeof point.commonName === "string" && point.commonName.trim()
              ? point.commonName.trim()
              : point.id,
        }))
        .sort((a, b) => a.commonName.localeCompare(b.commonName))
    : [];

  dockListCache = {
    docks,
    fetchedAt: now,
  };
  return docks;
}

function sanitizeBikePointQuery(rawQuery) {
  if (!rawQuery || typeof rawQuery !== "object") {
    return {};
  }

  const next = {};
  for (const [key, value] of Object.entries(rawQuery)) {
    if (key === "cb" || key === "_" || key === "cacheBuster") {
      continue;
    }
    next[key] = value;
  }
  return next;
}

app.get("/BikePoint", async (req, res) => {
  try {
    const bikePoints = await fetchTflJson(
      "/BikePoint",
      sanitizeBikePointQuery(req.query || {})
    );
    if (!Array.isArray(bikePoints)) {
      return res.json(bikePoints);
    }
    res.json(bikePoints.map((bikePoint) => applyOverrideToBikePoint(bikePoint)));
  } catch (err) {
    logger.error(`Failed to proxy /BikePoint: ${err.message}`);
    res.status(502).json({ error: "Failed to fetch BikePoint data from TfL" });
  }
});

app.get("/Place/:dockId", async (req, res) => {
  const dockId = req.params.dockId;
  if (!dockId) {
    return res.status(400).json({ error: "Missing required path param: dockId" });
  }

  try {
    const bikePoint = await fetchTflJson(`/Place/${dockId}`, req.query || {});
    res.json(applyOverrideToBikePoint(bikePoint));
  } catch (err) {
    logger.error(`Failed to proxy /Place/${dockId}: ${err.message}`);
    res.status(502).json({ error: `Failed to fetch dock ${dockId} from TfL` });
  }
});

const ADMIN_ROUTE_PREFIXES = ["/admin", "/my-boris-bikes/admin"];
const adminRoutePaths = (suffix = "") =>
  ADMIN_ROUTE_PREFIXES.map((prefix) => `${prefix}${suffix}`);

app.get(adminRoutePaths(""), (_req, res) => {
  res.set("Cache-Control", "no-store, no-cache, must-revalidate, proxy-revalidate");
  res.set("Pragma", "no-cache");
  res.set("Expires", "0");
  res.type("html").send(renderAdminOverridesPage());
});

app.get(adminRoutePaths("/overrides"), (req, res) => {
  res.redirect(req.path.replace(/\/overrides$/, ""));
});

app.get(adminRoutePaths("/api/docks"), async (_req, res) => {
  try {
    const docks = await fetchDockList();
    res.json({ count: docks.length, docks });
  } catch (err) {
    logger.error(`Failed to load dock list for admin UI: ${err.message}`);
    res.status(502).json({ error: "Failed to load dock list from TfL" });
  }
});

app.get(adminRoutePaths("/api/overrides"), (_req, res) => {
  res.json({
    count: dockOverrides.size,
    overrides: serializeDockOverrides(),
  });
});

app.post(adminRoutePaths("/api/overrides"), (req, res) => {
  const dockId =
    typeof req.body?.dockId === "string" ? req.body.dockId.trim() : "";
  const standardBikes = normalizeNonNegativeInteger(req.body?.standardBikes);
  const eBikes = normalizeNonNegativeInteger(req.body?.eBikes);
  const emptySpaces = normalizeNonNegativeInteger(req.body?.emptySpaces);

  if (!dockId) {
    return res.status(400).json({ error: "dockId is required" });
  }
  if (standardBikes === null || eBikes === null || emptySpaces === null) {
    return res.status(400).json({
      error: "standardBikes, eBikes, and emptySpaces must be integers >= 0",
    });
  }

  const override = {
    standardBikes,
    eBikes,
    emptySpaces,
    updatedAt: Date.now(),
  };
  dockOverrides.set(dockId, override);
  saveDockOverrides();

  logger.info(
    `Set dock override for ${dockId}: bikes=${standardBikes}, eBikes=${eBikes}, spaces=${emptySpaces}`
  );

  res.json({
    success: true,
    override: {
      dockId,
      standardBikes,
      eBikes,
      emptySpaces,
      updatedAt: new Date(override.updatedAt).toISOString(),
    },
  });
});

app.delete(adminRoutePaths("/api/overrides/:dockId"), (req, res) => {
  const dockId =
    typeof req.params?.dockId === "string" ? req.params.dockId.trim() : "";
  if (!dockId) {
    return res.status(400).json({ error: "dockId is required" });
  }

  const existed = dockOverrides.delete(dockId);
  if (existed) {
    saveDockOverrides();
    logger.info(`Cleared dock override for ${dockId}`);
  }

  res.json({ success: true, existed, dockId });
});

app.post("/live-activity/start", (req, res) => {
  const {
    dockId,
    dockName,
    pushToken,
    buildType,
    expirySeconds,
    alternatives,
    primaryDisplay,
    minimumThresholds,
  } = req.body;

  if (!dockId || !pushToken || !buildType) {
    return res
      .status(400)
      .json({ error: "Missing required fields: dockId, pushToken, buildType" });
  }

  if (buildType !== "development" && buildType !== "production") {
    return res
      .status(400)
      .json({ error: 'buildType must be "development" or "production"' });
  }

  // Use client-provided expiry or fall back to default timeout, but always cap the window.
  const expiryMs = resolveSessionExpiryMs(expirySeconds);
  const normalizedAlternatives = sanitizeAlternatives(alternatives);
  const normalizedPrimaryDisplay = sanitizePrimaryDisplay(primaryDisplay);
  const normalizedMinimumThresholds = sanitizeMinimumThresholds(minimumThresholds);
  const normalizedDockName = sanitizeDockName(dockName);
  const activeMinimumThreshold = minimumThresholdForDisplay(
    normalizedMinimumThresholds,
    normalizedPrimaryDisplay
  );
  const deviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  const startedAt = Date.now();
  const hardStopAt = startedAt + HARD_NOTIFICATION_CUTOFF_MS;

  if (!deviceToken && req.headers["x-device-token"]) {
    logger.warn(
      `Ignoring invalid APNs device token for live activity start (dock=${dockId})`
    );
  }

  logger.info(
    `Starting live activity: dock=${dockId}, build=${buildType}, primaryDisplay=${normalizedPrimaryDisplay}, minimumThreshold=${activeMinimumThreshold}, expires in ${expiryMs / 1000}s`
  );
  logger.info(`  pushToken: ${pushToken} (alternatives: ${normalizedAlternatives.length})`);

  // Register the token for this dock
  if (!dockPollers.has(dockId)) {
    dockPollers.set(dockId, {
      interval: null,
      lastData: null,
      tokens: new Map(),
    });
  }

  const poller = dockPollers.get(dockId);
  poller.tokens.set(pushToken, {
    buildType,
    startedAt,
    hardStopAt,
    expiryMs,
    dockName: normalizedDockName,
    alternatives: normalizedAlternatives,
    primaryDisplay: normalizedPrimaryDisplay,
    minimumThresholds: normalizedMinimumThresholds,
    deviceToken,
  });

  // Start polling if not already
  startPollingForDock(dockId);

  // Update metrics
  liveActivitiesTotal.inc({ build_type: buildType });
  updateLiveActivitiesActiveGauge();

  res.json({
    success: true,
    dockId,
    dockName: normalizedDockName || dockId,
    primaryDisplay: normalizedPrimaryDisplay,
    minimumThreshold: activeMinimumThreshold,
    hasDeviceToken: !!deviceToken,
    message: "Live activity started",
    expiresIn: `${Math.floor((sessionExpiresAtMs({ startedAt, hardStopAt, expiryMs }) - startedAt) / 1000)} seconds`,
  });
});

app.post("/live-activity/session/update", (req, res) => {
  const { dockId, pushToken, dockName, primaryDisplay, minimumThresholds } = req.body;

  if (!dockId || !pushToken) {
    return res
      .status(400)
      .json({ error: "Missing required fields: dockId, pushToken" });
  }

  const poller = dockPollers.get(dockId);
  if (!poller) {
    return res.status(404).json({ error: "Live activity session not found for dock" });
  }

  const session = poller.tokens.get(pushToken);
  if (!session) {
    return res.status(404).json({ error: "Live activity session token not found" });
  }

  if (primaryDisplay !== undefined) {
    session.primaryDisplay = sanitizePrimaryDisplay(primaryDisplay);
  }

  if (minimumThresholds !== undefined) {
    session.minimumThresholds = sanitizeMinimumThresholds(minimumThresholds);
  }

  if (dockName !== undefined) {
    session.dockName = sanitizeDockName(dockName);
  }

  const deviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  if (deviceToken) {
    session.deviceToken = deviceToken;
  } else if (req.headers["x-device-token"]) {
    logger.warn(
      `Ignoring invalid APNs device token for live activity session update (dock=${dockId})`
    );
  }

  const resolvedPrimaryDisplay = sanitizePrimaryDisplay(session.primaryDisplay);
  const resolvedMinimumThreshold = minimumThresholdForDisplay(
    session.minimumThresholds,
    resolvedPrimaryDisplay
  );

  logger.info(
    `Updated live activity session: dock=${dockId}, token=${pushToken.substring(0, 8)}..., primaryDisplay=${resolvedPrimaryDisplay}, minimumThreshold=${resolvedMinimumThreshold}`
  );

  res.json({
    success: true,
    dockId,
    dockName:
      session.dockName ||
      (typeof poller.lastData?.dockName === "string" &&
      poller.lastData.dockName.trim()
        ? poller.lastData.dockName.trim()
        : dockId),
    primaryDisplay: resolvedPrimaryDisplay,
    minimumThreshold: resolvedMinimumThreshold,
  });
});

app.post("/live-activity/end", async (req, res) => {
  const { dockId, pushToken } = req.body;

  if (!dockId || !pushToken) {
    return res
      .status(400)
      .json({ error: "Missing required fields: dockId, pushToken" });
  }

  logger.info(
    `Ending live activity: dock=${dockId}, token=${pushToken.substring(0, 8)}...`
  );

  const poller = dockPollers.get(dockId);
  if (poller) {
    const session = poller.tokens.get(pushToken);
    if (session) {
      // Send end event
      try {
        const lastData = poller.lastData || {
          standardBikes: 0,
          eBikes: 0,
          emptySpaces: 0,
        };
        const contentState = contentStateWithAlternatives(lastData, session);
        await sendApnsPush(pushToken, contentState, "end", session.buildType);
      } catch (err) {
        logger.error(`Failed to send end push:`, err.message);
      }
      poller.tokens.delete(pushToken);

      // Update metrics
      liveActivitiesEnded.inc({ reason: "user" });
    }

    // Stop polling if no tokens left
    if (poller.tokens.size === 0) {
      stopPollingForDock(dockId);
    }
  }

  // Update active count
  updateLiveActivitiesActiveGauge();

  res.json({ success: true, dockId, message: "Live activity ended" });
});

// ── Test Harness ──────────────────────────────────────────────────────
// Simulates frequent dock data changes for testing push notification updates.
// Instead of polling the real TfL API, generates randomised data every interval.
const testSessions = new Map(); // pushToken -> { interval, buildType, cycle }

app.post("/live-activity/test", (req, res) => {
  const { pushToken, buildType } = req.body;

  if (!pushToken || !buildType) {
    return res
      .status(400)
      .json({ error: "Missing required fields: pushToken, buildType" });
  }

  // If already running a test for this token, stop it first
  if (testSessions.has(pushToken)) {
    clearInterval(testSessions.get(pushToken).interval);
    testSessions.delete(pushToken);
  }

  const TEST_INTERVAL_MS = parseInt(
    process.env.TEST_INTERVAL_MS || "30000",
    10
  );
  let cycle = 0;

  logger.info(
    `Starting TEST session: token=${pushToken.substring(0, 8)}..., build=${buildType}, interval=${TEST_INTERVAL_MS}ms`
  );

  function generateTestData(cycle) {
    // Simulate a dock with ~22 total docks, values shifting each cycle
    const totalDocks = 22;
    const standardBikes = Math.max(0, Math.min(totalDocks, 5 + Math.round(Math.sin(cycle * 0.5) * 4)));
    const eBikes = Math.max(0, Math.min(totalDocks - standardBikes, 3 + Math.round(Math.cos(cycle * 0.7) * 3)));
    const emptySpaces = Math.max(0, totalDocks - standardBikes - eBikes);
    return { standardBikes, eBikes, emptySpaces };
  }

  // Send an immediate first update
  const initialData = generateTestData(cycle++);
  logger.info(
    `TEST update #${cycle}: bikes=${initialData.standardBikes}, eBikes=${initialData.eBikes}, spaces=${initialData.emptySpaces}`
  );
  sendApnsPush(pushToken, initialData, "update", buildType).catch((err) => {
    logger.error(`TEST push failed:`, err.message);
  });

  // Then send updates on the interval, always changing
  const interval = setInterval(async () => {
    const data = generateTestData(cycle++);
    logger.info(
      `TEST update #${cycle}: bikes=${data.standardBikes}, eBikes=${data.eBikes}, spaces=${data.emptySpaces}`
    );
    try {
      await sendApnsPush(pushToken, data, "update", buildType);
    } catch (err) {
      logger.error(`TEST push failed:`, err.message);
    }
  }, TEST_INTERVAL_MS);

  testSessions.set(pushToken, { interval, buildType, cycle });

  res.json({
    success: true,
    message: `Test session started — will push new data every ${TEST_INTERVAL_MS / 1000}s`,
    firstUpdate: initialData,
  });
});

app.post("/live-activity/test/end", (req, res) => {
  const { pushToken } = req.body;

  if (!pushToken) {
    return res.status(400).json({ error: "Missing required field: pushToken" });
  }

  const session = testSessions.get(pushToken);
  if (session) {
    clearInterval(session.interval);
    testSessions.delete(pushToken);
    logger.info(`Stopped TEST session for token ${pushToken.substring(0, 8)}...`);
    res.json({ success: true, message: "Test session ended" });
  } else {
    res.json({ success: false, message: "No test session found for this token" });
  }
});

app.post("/app/metrics", (req, res) => {
  const { deviceToken, screen, action, dock, metadata, buildType } = req.body || {};

  if (!action || !screen) {
    return res
      .status(400)
      .json({ error: "Missing required fields: action, screen" });
  }

  const headerDeviceToken = req.headers["x-device-token"];
  const resolvedDeviceToken = deviceToken || headerDeviceToken;
  if (resolvedDeviceToken) {
    trackDeviceToken(resolvedDeviceToken);
  }

  const dockId =
    dock && typeof dock.id === "string" && dock.id.trim()
      ? dock.id.trim()
      : "none";
  const dockName =
    dock && typeof dock.name === "string" && dock.name.trim()
      ? dock.name.trim()
      : "none";
  const buildTypeLabel =
    typeof buildType === "string" && buildType.trim()
      ? buildType.trim()
      : "unknown";

  appActionsTotal.inc({
    action,
    screen,
    dock_id: dockId,
    dock_name: dockName,
    build_type: buildTypeLabel,
  });

  if (dockStatsTrackedActions.has(action)) {
    dockStatsTotal.inc({
      action,
      screen,
      dock_id: dockId,
      dock_name: dockName,
      build_type: buildTypeLabel,
    });
  }

  const truncatedToken = resolvedDeviceToken
    ? `${resolvedDeviceToken.substring(0, 8)}...`
    : "none";
  logger.info(
    `App action: action=${action}, screen=${screen}, dock=${dockId}, name=${dockName}, build=${buildTypeLabel}, device=${truncatedToken}`
  );
  if (dock && typeof dock === "object") {
    logger.info(`App action dock: ${JSON.stringify(dock)}`);
  }
  if (metadata && typeof metadata === "object") {
    logger.info(`App action metadata: ${JSON.stringify(metadata)}`);
  }

  res.json({ success: true });
});

app.get("/healthcheck", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/metrics", async (_req, res) => {
  try {
    res.set("Content-Type", register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err);
  }
});

app.get("/status", (_req, res) => {
  const now = Date.now();
  const uptime = now - serverStartTime;
  const memUsage = process.memoryUsage();

  res.json({
    status: "running",
    uptime: {
      milliseconds: uptime,
      seconds: Math.floor(uptime / 1000),
      minutes: Math.floor(uptime / 1000 / 60),
      hours: Math.floor(uptime / 1000 / 60 / 60),
      formatted: formatUptime(uptime),
    },
    startedAt: new Date(serverStartTime).toISOString(),
    memory: {
      rss: `${(memUsage.rss / 1024 / 1024).toFixed(2)} MB`,
      heapTotal: `${(memUsage.heapTotal / 1024 / 1024).toFixed(2)} MB`,
      heapUsed: `${(memUsage.heapUsed / 1024 / 1024).toFixed(2)} MB`,
      external: `${(memUsage.external / 1024 / 1024).toFixed(2)} MB`,
    },
    server: {
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
      pid: process.pid,
    },
    config: {
      port: PORT,
      pollIntervalMs: POLL_INTERVAL_MS,
      sessionTimeoutHours: SESSION_TIMEOUT_MS / 1000 / 60 / 60,
      maxNotificationWindowHours:
        EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS / 1000 / 60 / 60,
      apnsEnvironment: {
        keyId: APNS_KEY_ID,
        teamId: APNS_TEAM_ID,
        topic: APNS_TOPIC,
        backgroundTopic: APNS_BACKGROUND_TOPIC,
      },
    },
    activity: {
      activeDockPollers: dockPollers.size,
      totalTrackedTokens: activeLiveActivityTokenCount(),
      activeTestSessions: testSessions.size,
      activeDockOverrides: dockOverrides.size,
      complicationTokens: complicationTokens.size,
      complicationRefreshIntervalSeconds: COMPLICATION_REFRESH_INTERVAL_MS / 1000,
    },
  });
});

app.get("/live-activity/status", (req, res) => {
  const status = {};
  for (const [dockId, poller] of dockPollers) {
    status[dockId] = {
      tokenCount: poller.tokens.size,
      lastData: poller.lastData,
      tokens: Array.from(poller.tokens.entries()).map(([token, session]) => ({
        token: token.substring(0, 8) + "...",
        buildType: session.buildType,
        primaryDisplay: sanitizePrimaryDisplay(session.primaryDisplay),
        minimumThresholds: session.minimumThresholds || null,
        activeMinimumThreshold: minimumThresholdForDisplay(
          session.minimumThresholds,
          sanitizePrimaryDisplay(session.primaryDisplay)
        ),
        deviceToken: session.deviceToken
          ? `${session.deviceToken.substring(0, 8)}...`
          : null,
        alternativesCount: Array.isArray(session.alternatives)
          ? session.alternatives.length
          : 0,
        dockName:
          session.dockName ||
          (typeof poller.lastData?.dockName === "string" &&
          poller.lastData.dockName.trim()
            ? poller.lastData.dockName.trim()
            : dockId),
        startedAt: new Date(sessionStartedAtMs(session)).toISOString(),
        expiresAt: new Date(sessionExpiresAtMs(session)).toISOString(),
      })),
    };
  }
  const testStatus = Array.from(testSessions.entries()).map(
    ([token, session]) => ({
      token: token.substring(0, 8) + "...",
      buildType: session.buildType,
    })
  );

  res.json({ activeSessions: status, testSessions: testStatus });
});

app.post("/live-activity/device/status", (req, res) => {
  const bodyDeviceToken = normalizeApnsDeviceToken(req.body?.deviceToken);
  const headerDeviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  const deviceToken = bodyDeviceToken || headerDeviceToken;
  const requestedBuildType =
    req.body?.buildType === "development" || req.body?.buildType === "production"
      ? req.body.buildType
      : null;

  if (!deviceToken) {
    return res
      .status(400)
      .json({ error: "Missing or invalid deviceToken (body.deviceToken or X-Device-Token)" });
  }

  const matchingSessions = collectSessionsForDevice(deviceToken, requestedBuildType);
  const latestSession = matchingSessions[0] || null;

  res.json({
    success: true,
    active: matchingSessions.length > 0,
    activeCount: matchingSessions.length,
    session: latestSession
      ? {
          dockId: latestSession.dockId,
          dockName: latestSession.dockName,
          startedAt: new Date(latestSession.startedAt).toISOString(),
          expiresAt: new Date(latestSession.expiresAtMs).toISOString(),
          buildType: latestSession.buildType,
        }
      : null,
  });
});

// ── Complication Refresh Endpoints ────────────────────────────────────

// Register a device token to receive periodic silent background pushes.
// The iOS app calls this on launch whenever it receives a fresh APNs device token.
app.post("/complication/register", (req, res) => {
  const { deviceToken, buildType } = req.body;

  if (!deviceToken || !buildType) {
    return res.status(400).json({ error: "Missing required fields: deviceToken, buildType" });
  }
  if (buildType !== "development" && buildType !== "production") {
    return res.status(400).json({ error: 'buildType must be "development" or "production"' });
  }

  const isNew = !complicationTokens.has(deviceToken);
  complicationTokens.set(deviceToken, { buildType, registeredAt: Date.now() });
  saveComplicationTokens();

  logger.info(
    `Complication token ${isNew ? "registered" : "refreshed"}: ` +
    `${deviceToken.substring(0, 8)}... (${buildType}, total: ${complicationTokens.size})`
  );

  res.json({
    success: true,
    message: "Registered for complication refresh",
    refreshIntervalSeconds: COMPLICATION_REFRESH_INTERVAL_MS / 1000,
  });
});

// Unregister a device token (e.g. on app uninstall / user opt-out).
app.post("/complication/unregister", (req, res) => {
  const { deviceToken } = req.body;

  if (!deviceToken) {
    return res.status(400).json({ error: "Missing required field: deviceToken" });
  }

  const existed = complicationTokens.delete(deviceToken);
  saveComplicationTokens();
  logger.info(
    `Complication token unregistered: ${deviceToken.substring(0, 8)}... ` +
    `(existed: ${existed}, remaining: ${complicationTokens.size})`
  );

  res.json({ success: true });
});

// Show registered complication tokens (truncated for privacy).
app.get("/complication/status", (_req, res) => {
  const tokens = Array.from(complicationTokens.entries()).map(
    ([token, { buildType, registeredAt }]) => ({
      token: token.substring(0, 8) + "...",
      buildType,
      registeredAt: new Date(registeredAt).toISOString(),
    })
  );
  res.json({
    count: complicationTokens.size,
    refreshIntervalSeconds: COMPLICATION_REFRESH_INTERVAL_MS / 1000,
    tokens,
  });
});

app.listen(PORT, () => {
  logger.info(`My Boris Bikes Live Activity server running on port ${PORT}`);
  logger.info(`Poll interval: ${POLL_INTERVAL_MS}ms`);
  logger.info(`Session timeout: ${SESSION_TIMEOUT_MS / 1000 / 60 / 60} hours`);
  logger.info(
    `Max notification window: ${EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS / 1000 / 60 / 60} hours`
  );
  logger.info(`APNS live activity topic: ${APNS_TOPIC}`);
  logger.info(`APNS app/background topic: ${APNS_BACKGROUND_TOPIC}`);
});
