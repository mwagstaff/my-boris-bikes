const express = require("express");
const jwt = require("jsonwebtoken");
const fs = require("fs");
const path = require("path");
const http2 = require("http2");
const winston = require("winston");
const promClient = require("prom-client");
const { MongoClient, ObjectId } = require("mongodb");
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
const START_ARRIVAL_DESTINATION_SPACE_ALERT_DELAY_MS = parseInt(
  process.env.START_ARRIVAL_DESTINATION_SPACE_ALERT_DELAY_MS || "30000",
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
const VALID_PRIMARY_DISPLAYS = new Set(["bikes", "eBikes", "allBikes", "spaces"]);
const MAX_PUSH_EVENT_LOG_ENTRIES = 500;
const MAX_BACKGROUND_LOCATION_EVENT_LOG_ENTRIES = 500;
const LIVE_ACTIVITY_ALERT_CATEGORY = "LIVE_ACTIVITY_ALERT";
const MONGODB_URI =
  process.env.MONGODB_URI_MY_BORIS_BIKES ||
  process.env.MONGODB_URI ||
  process.env.MONGO_URI ||
  "";
const MONGODB_DB_NAME = process.env.MONGODB_DB_NAME || "my_boris_bikes";
const SCHEDULED_JOURNEYS_COLLECTION =
  process.env.SCHEDULED_JOURNEYS_COLLECTION || "scheduled_journeys";
const SCHEDULED_JOURNEY_CHECK_INTERVAL_MS = parseInt(
  process.env.SCHEDULED_JOURNEY_CHECK_INTERVAL_MS || "60000",
  10
);
const MAX_SCHEDULED_JOURNEYS_PER_DEVICE = 5;
const MAX_SCHEDULED_JOURNEY_WINDOW_MINUTES = 12 * 60;

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
  labelNames: ["method", "url_path", "query_string", "status_code"],
  buckets: [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10],
  registers: [register],
});

const tflRequestsTotal = new promClient.Counter({
  name: "tfl_requests_total",
  help: "Total number of TfL API requests",
  labelNames: ["method", "url_path", "query_string", "status_code"],
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

const tflFreshnessState = {
  lastCheckedMs: null,
  lastModifiedMs: null,
  staleDocks: null,
  totalDocks: null,
  propertiesChecked: null,
};

const tflDataAgeSeconds = new promClient.Gauge({
  name: "tfl_data_age_seconds",
  help: "Current age in seconds of the most recently modified bike-count property in the full TfL /BikePoint feed",
  registers: [register],
  collect() {
    if (tflFreshnessState.lastModifiedMs !== null) {
      this.set(
        Math.max(0, (Date.now() - tflFreshnessState.lastModifiedMs) / 1000)
      );
    }
  },
});

const tflDataLastModifiedTimestampSeconds = new promClient.Gauge({
  name: "tfl_data_last_modified_timestamp_seconds",
  help: "Unix timestamp of the most recently modified bike-count property in the full TfL /BikePoint feed",
  registers: [register],
});

const tflDataLastCheckedTimestampSeconds = new promClient.Gauge({
  name: "tfl_data_last_checked_timestamp_seconds",
  help: "Unix timestamp when the full TfL /BikePoint freshness check last completed successfully",
  registers: [register],
});

const tflStaleDockRatio = new promClient.Gauge({
  name: "tfl_stale_dock_ratio",
  help: "Fraction of docks in the full TfL /BikePoint feed whose bike-count properties have not been modified within the staleness threshold",
  registers: [register],
});

const tflStaleDocksTotal = new promClient.Gauge({
  name: "tfl_stale_docks_total",
  help: "Number of docks in the full TfL /BikePoint feed whose bike-count properties have not been modified within the staleness threshold",
  registers: [register],
});

const tflDocksCheckedTotal = new promClient.Gauge({
  name: "tfl_docks_checked_total",
  help: "Number of docks in the full TfL /BikePoint feed with parseable bike-count modified timestamps",
  registers: [register],
});

const tflFreshnessPropertiesCheckedTotal = new promClient.Gauge({
  name: "tfl_freshness_properties_checked_total",
  help: "Number of bike-count modified timestamp properties checked in the last full TfL /BikePoint freshness check",
  registers: [register],
});

// Only these properties reflect actual bike availability; others (Installed, Locked, TerminalName)
// are updated by TfL even during a data freeze, so they would mask staleness.
const TFL_COUNT_KEYS = new Set([
  "NbBikes",
  "NbStandardBikes",
  "NbEBikes",
  "NbEmptyDocks",
]);
const TFL_STALENESS_THRESHOLD_MS = 10 * 60 * 1000; // 10 minutes

function updateTflBikePointFreshness(bikePoints) {
  if (!Array.isArray(bikePoints)) {
    logger.warn("TfL freshness: expected full /BikePoint array");
    return;
  }

  const now = Date.now();
  let maxModifiedMs = null;
  let totalDocks = 0;
  let staleDocks = 0;
  let propertiesChecked = 0;

  for (const bp of bikePoints) {
    let dockMaxMs = null;
    for (const prop of bp?.additionalProperties || []) {
      if (TFL_COUNT_KEYS.has(prop?.key) && prop?.modified) {
        propertiesChecked++;
        const t = new Date(prop.modified).getTime();
        if (!isNaN(t)) {
          if (dockMaxMs === null || t > dockMaxMs) dockMaxMs = t;
          if (maxModifiedMs === null || t > maxModifiedMs) maxModifiedMs = t;
        }
      }
    }
    if (dockMaxMs !== null) {
      totalDocks++;
      if (now - dockMaxMs > TFL_STALENESS_THRESHOLD_MS) staleDocks++;
    }
  }

  if (maxModifiedMs !== null) {
    tflFreshnessState.lastCheckedMs = now;
    tflFreshnessState.lastModifiedMs = maxModifiedMs;
    tflFreshnessState.staleDocks = staleDocks;
    tflFreshnessState.totalDocks = totalDocks;
    tflFreshnessState.propertiesChecked = propertiesChecked;

    const ageSeconds = Math.max(0, (now - maxModifiedMs) / 1000);
    tflDataAgeSeconds.set(ageSeconds);
    tflDataLastModifiedTimestampSeconds.set(maxModifiedMs / 1000);
    tflDataLastCheckedTimestampSeconds.set(now / 1000);
    tflStaleDockRatio.set(totalDocks > 0 ? staleDocks / totalDocks : 0);
    tflStaleDocksTotal.set(staleDocks);
    tflDocksCheckedTotal.set(totalDocks);
    tflFreshnessPropertiesCheckedTotal.set(propertiesChecked);

    logger.info(
      `TfL freshness: age=${Math.round(ageSeconds)}s, stale=${staleDocks}/${totalDocks} docks, ` +
      `last_modified=${new Date(maxModifiedMs).toISOString()} (${propertiesChecked} props checked)`
    );
  } else {
    logger.warn(
      `TfL freshness: no parseable modified timestamps on count properties ` +
      `across ${bikePoints.length} dock(s) - ${propertiesChecked} props checked`
    );
  }
}

const TFL_FRESHNESS_CHECK_INTERVAL_MS = 2 * 60 * 1000; // 2 minutes

async function checkTflDataFreshness() {
  try {
    const bikePoints = await fetchTflJson("/BikePoint");
    if (!Array.isArray(bikePoints) || bikePoints.length === 0) {
      logger.warn("TfL freshness check: unexpected /BikePoint response");
      return;
    }
    updateTflBikePointFreshness(bikePoints);
  } catch (err) {
    logger.error(`TfL freshness check failed: ${err.message}`);
  }
}

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

// ── Scheduled Journeys Persistence ───────────────────────────────────
let mongoClient = null;
let scheduledJourneysCollection = null;

async function connectMongoIfConfigured() {
  if (!MONGODB_URI) {
    logger.warn(
      "MONGODB_URI_MY_BORIS_BIKES is not configured; scheduled journey endpoints will return 503"
    );
    return;
  }

  try {
    mongoClient = new MongoClient(MONGODB_URI);
    await mongoClient.connect();
    const db = mongoClient.db(MONGODB_DB_NAME);
    scheduledJourneysCollection = db.collection(SCHEDULED_JOURNEYS_COLLECTION);
    await scheduledJourneysCollection.createIndex({ deviceId: 1, deletedAt: 1 });
    await scheduledJourneysCollection.createIndex({ enabled: 1, deletedAt: 1 });
    logger.info(
      `Connected to MongoDB database ${MONGODB_DB_NAME}, collection ${SCHEDULED_JOURNEYS_COLLECTION}`
    );
  } catch (err) {
    scheduledJourneysCollection = null;
    logger.error(`MongoDB connection failed: ${err.message}`);
  }
}

async function requireScheduledJourneysCollection(res) {
  if (scheduledJourneysCollection) return scheduledJourneysCollection;
  await connectMongoIfConfigured();
  if (scheduledJourneysCollection) return scheduledJourneysCollection;
  res.status(503).json({ error: "Scheduled journeys storage is not configured" });
  return null;
}

function normalizeDeviceId(rawValue) {
  if (typeof rawValue !== "string") return "";
  return rawValue.trim().slice(0, 128);
}

function deviceIdFromRequest(req) {
  return normalizeDeviceId(
    req.headers["x-device-id"] || req.body?.deviceId || req.query?.deviceId
  );
}

async function completeScheduledJourneyFromArrivalSession(session, dockId) {
  if (
    !session ||
    session.scheduledJourneyPhase !== "end" ||
    typeof session.scheduledJourneyId !== "string" ||
    !ObjectId.isValid(session.scheduledJourneyId)
  ) {
    return false;
  }

  if (!scheduledJourneysCollection) {
    await connectMongoIfConfigured();
  }
  if (!scheduledJourneysCollection) return false;

  const journeyId = session.scheduledJourneyId;
  const result = await scheduledJourneysCollection.updateOne(
    {
      _id: new ObjectId(journeyId),
      deletedAt: { $exists: false },
      "activeRun.phase": { $in: ["start", "end"] },
    },
    { $set: { activeRun: null, updatedAt: new Date() } }
  );

  const completed = result.modifiedCount > 0;
  appendDiagnosticJsonLine("scheduled_journey_completed_from_arrival", {
    journeyId,
    dockId,
    completed,
    matchedCount: result.matchedCount,
  });
  return completed;
}

function sanitizeJourneyDock(rawDock) {
  if (!rawDock || typeof rawDock !== "object") return null;
  const id = typeof rawDock.id === "string" ? rawDock.id.trim() : "";
  const name = typeof rawDock.name === "string" ? rawDock.name.trim() : "";
  const latitude = Number(rawDock.latitude);
  const longitude = Number(rawDock.longitude);
  if (!id || !name) return null;
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) return null;
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) return null;
  return { id, name, latitude, longitude };
}

function sanitizeWeekdays(rawWeekdays) {
  if (!Array.isArray(rawWeekdays)) return null;
  const unique = Array.from(
    new Set(
      rawWeekdays
        .map((value) => Number(value))
        .filter((value) => Number.isInteger(value) && value >= 1 && value <= 7)
    )
  ).sort((a, b) => a - b);
  return unique.length > 0 ? unique : null;
}

function parseMinutesSinceMidnight(rawValue) {
  if (typeof rawValue !== "string") return null;
  const match = rawValue.trim().match(/^([01]\d|2[0-3]):([0-5]\d)$/);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

function scheduledWindowMinutes(startTime, endTime) {
  const startMinutes = parseMinutesSinceMidnight(startTime);
  const endMinutes = parseMinutesSinceMidnight(endTime);
  if (startMinutes === null || endMinutes === null) return null;
  const diff = (endMinutes - startMinutes + 24 * 60) % (24 * 60);
  return diff === 0 ? 24 * 60 : diff;
}

function sanitizeTimeZone(rawValue) {
  const timezone = typeof rawValue === "string" && rawValue.trim()
    ? rawValue.trim()
    : "Europe/London";
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone: timezone }).format(new Date());
    return timezone;
  } catch {
    return null;
  }
}

function sanitizeScheduledJourneyPayload(body) {
  const startDock = sanitizeJourneyDock(body?.startDock);
  const endDock = sanitizeJourneyDock(body?.endDock);
  const weekdays = sanitizeWeekdays(body?.weekdays);
  const startTime = typeof body?.startTime === "string" ? body.startTime.trim() : "";
  const endTime = typeof body?.endTime === "string" ? body.endTime.trim() : "";
  const timezone = sanitizeTimeZone(body?.timezone);
  const windowMinutes = scheduledWindowMinutes(startTime, endTime);

  if (!startDock || !endDock) return { error: "Valid startDock and endDock are required" };
  if (startDock.id === endDock.id) return { error: "Start and end docks must be different" };
  if (!weekdays) return { error: "At least one weekday is required" };
  if (!timezone) return { error: "Invalid timezone" };
  if (windowMinutes === null) return { error: "startTime and endTime must use HH:mm" };
  if (windowMinutes > MAX_SCHEDULED_JOURNEY_WINDOW_MINUTES) {
    return { error: "Scheduled journey window cannot exceed 12 hours" };
  }

  return {
    value: {
      startDock,
      endDock,
      weekdays,
      startTime,
      endTime,
      timezone,
      enabled: body?.enabled !== false,
      bikeDataFilter: sanitizeBikeDataFilter(body?.bikeDataFilter),
    },
  };
}

function serializeScheduledJourney(doc) {
  return {
    id: doc._id.toString(),
    deviceId: doc.deviceId,
    startDock: doc.startDock,
    endDock: doc.endDock,
    weekdays: doc.weekdays || [],
    startTime: doc.startTime,
    endTime: doc.endTime,
    timezone: doc.timezone || "Europe/London",
    enabled: doc.enabled !== false,
    bikeDataFilter: sanitizeBikeDataFilter(doc.bikeDataFilter),
    activeRun: doc.activeRun || null,
    pausedRunKeys: doc.pausedRunKeys || [],
    createdAt: doc.createdAt?.toISOString?.() || doc.createdAt,
    updatedAt: doc.updatedAt?.toISOString?.() || doc.updatedAt,
  };
}

function scheduledJourneyPhaseFromValues(...values) {
  for (const value of values) {
    if (value === "end" || value === "start") return value;
  }
  return null;
}

function sanitizeBikeDataFilter(rawValue) {
  return rawValue === "bikesOnly" || rawValue === "eBikesOnly" || rawValue === "both"
    ? rawValue
    : "both";
}

function localDateParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const weekdayMap = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  return {
    weekday: weekdayMap[lookup.weekday],
    dateKey: `${lookup.year}-${lookup.month}-${lookup.day}`,
    time: `${lookup.hour}:${lookup.minute}`,
  };
}

function scheduledRunKey(journey, date = new Date()) {
  const parts = localDateParts(date, journey.timezone || "Europe/London");
  return `${parts.dateKey}:${journey.startTime}`;
}

function shouldStartScheduledJourney(journey, date = new Date()) {
  return scheduledJourneyStartDecision(journey, date).canStart;
}

function scheduledJourneyStartDecision(journey, date = new Date()) {
  if (journey.enabled === false) {
    return { canStart: false, reason: "disabled" };
  }
  if (journey.deletedAt) {
    return { canStart: false, reason: "deleted" };
  }

  const parts = localDateParts(date, journey.timezone || "Europe/London");
  const runKey = `${parts.dateKey}:${journey.startTime}`;
  const base = { parts, runKey };
  if (!journey.weekdays?.includes(parts.weekday)) {
    return { canStart: false, reason: "weekday_mismatch", ...base };
  }
  if (parts.time !== journey.startTime) {
    return { canStart: false, reason: "time_mismatch", ...base };
  }

  if (journey.activeRun?.phase) {
    if (journey.activeRun.runKey === runKey) {
      return { canStart: false, reason: "already_active_for_run", ...base };
    }
    const activeStartedAt = journey.activeRun.startedAt
      ? new Date(journey.activeRun.startedAt)
      : null;
    if (activeStartedAt && !Number.isNaN(activeStartedAt.getTime())) {
      const activeParts = localDateParts(
        activeStartedAt,
        journey.timezone || "Europe/London"
      );
      if (activeParts.dateKey === parts.dateKey) {
        return { canStart: false, reason: "already_active_today", activeParts, ...base };
      }
    }
  }

  if (Array.isArray(journey.pausedRunKeys) && journey.pausedRunKeys.includes(runKey)) {
    return { canStart: false, reason: "run_paused", ...base };
  }

  return { canStart: true, reason: "eligible", ...base };
}

function appendScheduledJourneyCheckDiagnostic(kind, journey, decision, extra = {}) {
  appendDiagnosticJsonLine(kind, {
    journeyId: journey._id?.toString?.() || null,
    deviceId: shortenIdentifier(journey.deviceId),
    startDockId: journey.startDock?.id || null,
    startDockName: journey.startDock?.name || null,
    endDockId: journey.endDock?.id || null,
    endDockName: journey.endDock?.name || null,
    startTime: journey.startTime || null,
    endTime: journey.endTime || null,
    timezone: journey.timezone || "Europe/London",
    weekdays: journey.weekdays || [],
    runKey: decision?.runKey || null,
    localDateKey: decision?.parts?.dateKey || null,
    localTime: decision?.parts?.time || null,
    localWeekday: decision?.parts?.weekday || null,
    reason: decision?.reason || null,
    enabled: journey.enabled !== false,
    hasDeviceToken: !!normalizeApnsDeviceToken(journey.deviceToken),
    hasPushToStartToken: !!normalizeApnsDeviceToken(journey.pushToStartToken),
    activeRun: journey.activeRun || null,
    pausedRunKeys: journey.pausedRunKeys || [],
    ...extra,
  });
}

function shouldEndScheduledJourneyWindow(journey, date = new Date()) {
  if (!journey.activeRun?.phase) return false;
  const parts = localDateParts(date, journey.timezone || "Europe/London");
  if (parts.time === journey.endTime) return true;

  const activeStartedAt = journey.activeRun.startedAt
    ? new Date(journey.activeRun.startedAt)
    : null;
  if (!activeStartedAt || Number.isNaN(activeStartedAt.getTime())) return false;

  const windowMinutes = scheduledWindowMinutes(journey.startTime, journey.endTime);
  if (windowMinutes === null) {
    return false;
  }

  return date.getTime() - activeStartedAt.getTime() >= windowMinutes * 60 * 1000;
}

// ── Dock Value Overrides ─────────────────────────────────────────────
// Map<dockId, { standardBikes: number, eBikes: number, emptySpaces: number, latitude: number|null, longitude: number|null, updatedAt: number }>
const dockOverrides = new Map();

function parseOptionalCoordinate(value, min, max) {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string" && !value.trim()) return undefined;
  const numericValue = Number(value);
  if (!Number.isFinite(numericValue) || numericValue < min || numericValue > max) {
    return null;
  }
  return numericValue;
}

function loadDockOverrides() {
  try {
    if (!fs.existsSync(DOCK_OVERRIDES_PATH)) return;
    const raw = fs.readFileSync(DOCK_OVERRIDES_PATH, "utf8");
    const entries = JSON.parse(raw);
    for (const [dockId, override] of entries) {
      if (!dockId || typeof override !== "object" || !override) continue;
      const latitude = parseOptionalCoordinate(
        override.latitude ?? override.lat,
        -90,
        90
      );
      const longitude = parseOptionalCoordinate(
        override.longitude ?? override.lon,
        -180,
        180
      );
      const hasLocationOverride =
        typeof latitude === "number" && typeof longitude === "number";
      dockOverrides.set(dockId, {
        standardBikes: Math.max(0, Math.trunc(Number(override.standardBikes) || 0)),
        eBikes: Math.max(0, Math.trunc(Number(override.eBikes) || 0)),
        emptySpaces: Math.max(0, Math.trunc(Number(override.emptySpaces) || 0)),
        latitude: hasLocationOverride ? latitude : null,
        longitude: hasLocationOverride ? longitude : null,
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
const REDACTED_TFL_QUERY_KEYS = new Set([
  "app_key",
  "api_key",
  "key",
  "subscription-key",
  "subscription_key",
]);
const VOLATILE_TFL_QUERY_KEYS = new Set(["_", "cb", "cachebuster"]);

function tflQueryStringMetricLabel(params) {
  const entries = Array.from(params.entries());
  if (entries.length === 0) return "(none)";

  return entries
    .map(([key, value]) => {
      const normalizedKey = key.toLowerCase();
      if (REDACTED_TFL_QUERY_KEYS.has(normalizedKey)) {
        return [key, "<redacted>"];
      }
      if (VOLATILE_TFL_QUERY_KEYS.has(normalizedKey)) {
        return [key, "<cache-buster>"];
      }
      return [key, value];
    })
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => {
      const metricValue =
        value.startsWith("<") && value.endsWith(">")
          ? value
          : encodeURIComponent(value);
      return `${encodeURIComponent(key)}=${metricValue}`;
    })
    .join("&");
}

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
  const queryStringMetric = tflQueryStringMetricLabel(params);
  const url = `${TFL_API_BASE}${urlPath}${queryString ? `?${queryString}` : ""}`;
  const method = "GET";
  const start = Date.now();

  let res;
  try {
    res = await fetch(url);
  } catch (err) {
    const duration = (Date.now() - start) / 1000;
    tflRequestDuration.observe(
      {
        method,
        url_path: urlPath,
        query_string: queryStringMetric,
        status_code: "error",
      },
      duration
    );
    tflRequestsTotal.inc({
      method,
      url_path: urlPath,
      query_string: queryStringMetric,
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
    {
      method,
      url_path: urlPath,
      query_string: queryStringMetric,
      status_code: statusCode,
    },
    duration
  );
  tflRequestsTotal.inc({
    method,
    url_path: urlPath,
    query_string: queryStringMetric,
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

const scheduledStartArrivalDestinationAlerts = new Map();

function startArrivalDestinationAlertKey(deviceToken, startDockId, endDockId) {
  return `${deviceToken}:${startDockId}:${endDockId}`;
}

function scheduleStartArrivalDestinationSpaceAlert({
  deviceToken,
  buildType,
  startDockId,
  startDockName,
  endDock,
  minimumSpaces,
  delayMs,
  scheduledJourneyId,
  adHocJourneyId,
}) {
  const key = startArrivalDestinationAlertKey(deviceToken, startDockId, endDock.id);
  const existingTimeout = scheduledStartArrivalDestinationAlerts.get(key);
  if (existingTimeout) {
    clearTimeout(existingTimeout);
  }

  const timeout = setTimeout(async () => {
    scheduledStartArrivalDestinationAlerts.delete(key);

    try {
      const endDockData = await fetchDockData(endDock.id);
      const resolvedDockName = endDockData.dockName || endDock.name || endDock.id;
      const alertBody = buildAvailabilitySnapshotMessage(
        resolvedDockName,
        "spaces",
        endDockData.emptySpaces,
        minimumSpaces
      );

      await sendAvailabilityAlertPush(
        deviceToken,
        buildType,
        alertBody,
        endDock.id,
        resolvedDockName
      );

      appendDiagnosticJsonLine("scheduled_start_arrival_destination_space_alert_sent", {
        startDockId,
        startDockName,
        endDockId: endDock.id,
        endDockName: resolvedDockName,
        deviceToken: shortenIdentifier(deviceToken),
        buildType,
        delayMs,
        scheduledJourneyId: scheduledJourneyId || null,
        adHocJourneyId: adHocJourneyId || null,
        emptySpaces: endDockData.emptySpaces,
        minimumSpaces,
      });
    } catch (err) {
      logger.error(
        `Failed to send delayed destination space alert for ${endDock.id}:`,
        err.message
      );
      appendDiagnosticJsonLine("scheduled_start_arrival_destination_space_alert_failed", {
        startDockId,
        endDockId: endDock.id,
        deviceToken: shortenIdentifier(deviceToken),
        buildType,
        delayMs,
        scheduledJourneyId: scheduledJourneyId || null,
        adHocJourneyId: adHocJourneyId || null,
        error: err.message,
      });
    }
  }, delayMs);

  scheduledStartArrivalDestinationAlerts.set(key, timeout);
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
    lat:
      typeof override.latitude === "number" ? override.latitude : bikePoint.lat,
    lon:
      typeof override.longitude === "number" ? override.longitude : bikePoint.lon,
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
        scheduledJourneyId: session.scheduledJourneyId || null,
        scheduledJourneyPhase: session.scheduledJourneyPhase || null,
      });
    }
  }

  return matches.sort((a, b) => b.startedAt - a.startedAt);
}

function primaryValueForDisplay(data, primaryDisplay) {
  switch (primaryDisplay) {
    case "allBikes":
      return data.standardBikes + data.eBikes;
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
    case "allBikes":
      return "bike";
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
    case "allBikes":
      return "bikes";
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
  if (primaryDisplay === "allBikes") {
    return sanitizeThresholdValue(minimumThresholds.bikes) +
      sanitizeThresholdValue(minimumThresholds.eBikes);
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

function buildAvailabilitySnapshotMessage(
  dockName,
  primaryDisplay,
  currentValue,
  minimumThreshold = 0
) {
  const safeDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "This dock";
  const sanitizedCurrentValue = sanitizeThresholdValue(currentValue);
  const normalizedThreshold = sanitizeThresholdValue(minimumThreshold);

  if (sanitizedCurrentValue === 0) {
    return `‼️ ${safeDockName} now has no ${pluralMetricLabel(primaryDisplay)} available`;
  }

  const metricLabel = metricLabelForValue(primaryDisplay, sanitizedCurrentValue);
  if (normalizedThreshold > 0 && sanitizedCurrentValue < normalizedThreshold) {
    return `⚠️ ${safeDockName} only has ${sanitizedCurrentValue} ${metricLabel} available`;
  }

  return `✅ ${safeDockName} now has ${sanitizedCurrentValue} ${metricLabel} available`;
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
  const activeDockId =
    typeof session?.activeDockId === "string" && session.activeDockId.trim()
      ? session.activeDockId.trim()
      : null;
  const activeDockName =
    typeof session?.activeDockName === "string" && session.activeDockName.trim()
      ? session.activeDockName.trim()
      : typeof data?.dockName === "string" && data.dockName.trim()
        ? data.dockName.trim()
        : null;
  const activeDockAlias =
    typeof session?.activeDockAlias === "string" && session.activeDockAlias.trim()
      ? session.activeDockAlias.trim()
      : null;

  return {
    standardBikes: data.standardBikes,
    eBikes: data.eBikes,
    emptySpaces: data.emptySpaces,
    alternatives: session?.alternatives || [],
    activeDockId,
    activeDockName,
    activeDockAlias,
    activeJourneyPhase: session?.scheduledJourneyPhase || null,
    primaryDisplay: sanitizePrimaryDisplay(session?.primaryDisplay),
  };
}

// ── APNS Push ────────────────────────────────────────────────────────
function getApnsHost(buildType) {
  return buildType === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
}

function oppositeBuildType(buildType) {
  return buildType === "production" ? "development" : "production";
}

function parseApnsReason(responseData) {
  if (!responseData) return null;
  try {
    const parsed = JSON.parse(responseData);
    return typeof parsed?.reason === "string" ? parsed.reason : null;
  } catch {
    return null;
  }
}

function buildApnsError(statusCode, responseData, buildType, deviceToken, logLabel) {
  const reason = parseApnsReason(responseData);
  const error = new Error(`APNS returned ${statusCode}: ${responseData}`);
  error.apns = {
    statusCode,
    responseData,
    reason,
    buildType,
    deviceToken,
    logLabel,
  };
  return error;
}

function isApnsTokenInvalidError(err) {
  const reason = err?.apns?.reason;
  if (reason === "BadDeviceToken" || reason === "Unregistered") {
    return true;
  }
  const body = `${err?.apns?.responseData || ""} ${err?.message || ""}`;
  return body.includes("BadDeviceToken") || body.includes("Unregistered");
}

function shouldRetryOnAlternateApnsHost(err) {
  return err?.apns?.statusCode === 400 && err?.apns?.reason === "BadDeviceToken";
}

function sendApnsRequestOnce(deviceToken, buildType, payload, buildHeaders, logLabel) {
  return new Promise((resolve, reject) => {
    const host = getApnsHost(buildType);
    const authToken = getApnsJwt();
    const client = http2.connect(`https://${host}`);
    let settled = false;
    let responseData = "";
    let statusCode;

    const settleReject = (error) => {
      if (settled) return;
      settled = true;
      try {
        client.close();
      } catch {
        // noop
      }
      reject(error);
    };

    const settleResolve = (value) => {
      if (settled) return;
      settled = true;
      try {
        client.close();
      } catch {
        // noop
      }
      resolve(value);
    };

    client.on("error", (err) => {
      const wrapped = new Error(`APNS connection error (${host}): ${err.message}`);
      wrapped.apns = {
        statusCode: null,
        responseData: err.message,
        reason: null,
        buildType,
        deviceToken,
        logLabel,
      };
      settleReject(wrapped);
    });

    const req = client.request(buildHeaders(deviceToken, authToken));
    req.on("response", (headers) => {
      statusCode = headers[":status"];
    });
    req.on("data", (chunk) => {
      responseData += chunk;
    });
    req.on("end", () => {
      if (statusCode === 200) {
        settleResolve({ statusCode, buildType, host });
        return;
      }
      settleReject(
        buildApnsError(statusCode, responseData, buildType, deviceToken, logLabel)
      );
    });
    req.on("error", (err) => {
      const wrapped = new Error(`APNS request error (${host}): ${err.message}`);
      wrapped.apns = {
        statusCode,
        responseData: err.message,
        reason: null,
        buildType,
        deviceToken,
        logLabel,
      };
      settleReject(wrapped);
    });

    req.end(payload);
  });
}

async function sendApnsRequestWithFallback(
  deviceToken,
  buildType,
  payload,
  buildHeaders,
  logLabel
) {
  try {
    return await sendApnsRequestOnce(
      deviceToken,
      buildType,
      payload,
      buildHeaders,
      logLabel
    );
  } catch (primaryError) {
    if (!shouldRetryOnAlternateApnsHost(primaryError)) {
      throw primaryError;
    }

    const fallbackBuildType = oppositeBuildType(buildType);
    logger.warn(
      `APNS ${logLabel} returned BadDeviceToken on ${buildType}; retrying ${fallbackBuildType} for ${deviceToken.substring(0, 8)}...`
    );

    const fallbackResult = await sendApnsRequestOnce(
      deviceToken,
      fallbackBuildType,
      payload,
      buildHeaders,
      logLabel
    );

    logger.info(
      `APNS ${logLabel} succeeded on fallback host (${fallbackBuildType}) for ${deviceToken.substring(0, 8)}...`
    );
    return fallbackResult;
  }
}

async function sendApnsPush(pushToken, contentState, event, buildType) {
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

  try {
    const result = await sendApnsRequestWithFallback(
      pushToken,
      buildType,
      payload,
      (token, authToken) => ({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${authToken}`,
        "apns-topic": APNS_TOPIC,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
        "content-type": "application/json",
      }),
      `liveactivity ${event}`
    );
    recordPushEvent({
      target: pushToken,
      channel: "live_activity",
      type: `live_activity_${event}`,
      result: "ok",
      status: result.statusCode,
      apnsEnv: result.buildType,
      raw: { event, contentState },
    });
    apnsPushesTotal.inc({ event, build_type: result.buildType, status: "success" });
    return { status: result.statusCode, buildType: result.buildType };
  } catch (err) {
    const metricBuildType = err?.apns?.buildType || buildType;
    const statusCode = err?.apns?.statusCode ?? "unknown";
    const responseData = err?.apns?.responseData || err.message;
    recordPushEvent({
      target: pushToken,
      channel: "live_activity",
      type: `live_activity_${event}`,
      result: "error",
      status: statusCode,
      error: responseData,
      apnsEnv: metricBuildType,
      raw: { event, contentState },
    });
    apnsPushesTotal.inc({ event, build_type: metricBuildType, status: "failure" });
    logger.error(
      `APNS push failed (${statusCode}): ${responseData} [token: ${pushToken.substring(0, 8)}...]`
    );
    throw err;
  }
}

async function sendScheduledJourneyStartPush(journey, reason = "schedule") {
  const token = normalizeApnsDeviceToken(journey.pushToStartToken);
  if (!token) {
    throw new Error("Scheduled journey is missing a push-to-start token");
  }

  const startDock = journey.startDock;
  const endDock = journey.endDock;
  let startDockData = null;
  try {
    startDockData = await fetchDockData(startDock.id);
  } catch (err) {
    logger.warn(
      `Failed to fetch initial scheduled journey dock data for ${startDock.id}: ${err.message}`
    );
  }
  const contentState = {
    standardBikes: sanitizeThresholdValue(startDockData?.standardBikes),
    eBikes: sanitizeThresholdValue(startDockData?.eBikes),
    emptySpaces: sanitizeThresholdValue(startDockData?.emptySpaces),
    alternatives: [],
  };
  const aps = {
    timestamp: Math.floor(Date.now() / 1000),
    event: "start",
    "content-state": contentState,
    "attributes-type": "DockActivityAttributes",
    attributes: {
      dockId: startDock.id,
      dockName: startDock.name,
      alias: null,
      scheduledJourneyId: journey._id.toString(),
      scheduledJourneyPhase: "start",
      latitude: startDock.latitude,
      longitude: startDock.longitude,
      destinationDockId: endDock.id,
      destinationDockName: endDock.name,
      destinationLatitude: endDock.latitude,
      destinationLongitude: endDock.longitude,
    },
    "input-push-token": 1,
    alert: {
      title: "Scheduled journey",
      body: `Live updates started for ${startDock.name}`,
      sound: "default",
    },
  };
  const payload = JSON.stringify({ aps });
  const buildType = journey.buildType === "production" ? "production" : "development";

  const result = await sendApnsRequestWithFallback(
    token,
    buildType,
    payload,
    (pushToken, authToken) => ({
      ":method": "POST",
      ":path": `/3/device/${pushToken}`,
      authorization: `bearer ${authToken}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    }),
    "scheduled liveactivity start"
  );

  recordPushEvent({
    target: token,
    channel: "live_activity",
    type: "scheduled_journey_start",
    title: "Scheduled journey",
    body: `Live updates started for ${startDock.name}`,
    result: "ok",
    status: result.statusCode,
    apnsEnv: result.buildType,
    raw: { journeyId: journey._id.toString(), reason },
  });
  apnsPushesTotal.inc({
    event: "scheduled_journey_start",
    build_type: result.buildType,
    status: "success",
  });
  return result;
}

function journeySessionPhase(session) {
  return session?.scheduledJourneyPhase === "end" || session?.activeJourneyPhase === "end"
    ? "end"
    : session?.scheduledJourneyPhase === "start" || session?.activeJourneyPhase === "start"
      ? "start"
      : null;
}

function isPreStartAdHocJourneySession(session) {
  return (
    journeySessionPhase(session) === "start" &&
    !session?.scheduledJourneyId
  );
}

function isInProgressJourneySession(session) {
  return journeySessionPhase(session) === "end";
}

async function prepareScheduledJourneyStart(journey, reason) {
  const deviceToken = normalizeApnsDeviceToken(journey.deviceToken);
  if (!deviceToken) {
    return { canStart: true, endedPreStartAdHocCount: 0, inProgressCount: 0 };
  }

  let inProgressCount = 0;
  for (const poller of dockPollers.values()) {
    for (const session of poller.tokens.values()) {
      if (session.deviceToken !== deviceToken) continue;
      if (isInProgressJourneySession(session)) {
        inProgressCount += 1;
      }
    }
  }

  if (inProgressCount > 0) {
    appendDiagnosticJsonLine("scheduled_journey_start_not_overriding_in_progress", {
      journeyId: journey._id?.toString?.() || null,
      deviceToken: shortenIdentifier(deviceToken),
      reason,
      inProgressCount,
    });
    logger.info(
      `Skipped scheduled journey ${journey._id} start because ${inProgressCount} journey session(s) are already in progress`
    );
    return { canStart: false, endedPreStartAdHocCount: 0, inProgressCount };
  }

  let endedPreStartAdHocCount = 0;
  for (const dockId of Array.from(dockPollers.keys())) {
    const result = await endTrackedSessionsForDock(
      dockId,
      (_pushToken, session) =>
        session.deviceToken === deviceToken &&
        isPreStartAdHocJourneySession(session),
      "scheduled_start_override_ad_hoc"
    );
    endedPreStartAdHocCount += result.endedCount;
  }

  if (endedPreStartAdHocCount > 0) {
    appendDiagnosticJsonLine("scheduled_journey_start_overrode_pre_start_ad_hoc", {
      journeyId: journey._id?.toString?.() || null,
      deviceToken: shortenIdentifier(deviceToken),
      reason,
      endedCount: endedPreStartAdHocCount,
    });
    logger.info(
      `Ended ${endedPreStartAdHocCount} pre-start ad-hoc journey session(s) before starting scheduled journey ${journey._id}`
    );
  }

  return { canStart: true, endedPreStartAdHocCount, inProgressCount: 0 };
}

function scheduledJourneyStartAlertBody(dockName, dockData, bikeDataFilter) {
  const resolvedDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "Start dock";
  const standardBikes = sanitizeThresholdValue(dockData?.standardBikes);
  const eBikes = sanitizeThresholdValue(dockData?.eBikes);

  switch (sanitizeBikeDataFilter(bikeDataFilter)) {
    case "bikesOnly":
      return `${resolvedDockName}: ${standardBikes} ${standardBikes === 1 ? "bike" : "bikes"}`;
    case "eBikesOnly":
      return `${resolvedDockName}: ${eBikes} ${eBikes === 1 ? "e-bike" : "e-bikes"}`;
    case "both":
    default:
      return `${resolvedDockName}: ${standardBikes} ${standardBikes === 1 ? "bike" : "bikes"}, ${eBikes} ${eBikes === 1 ? "e-bike" : "e-bikes"}`;
  }
}

async function sendScheduledJourneyInitialAvailabilityPush(journey) {
  const deviceToken = normalizeApnsDeviceToken(journey.deviceToken);
  if (!deviceToken) return null;

  const dockData = await fetchDockData(journey.startDock.id);
  return sendAlertPush(
    deviceToken,
    journey.buildType === "production" ? "production" : "development",
    "Scheduled journey",
    scheduledJourneyStartAlertBody(
      journey.startDock.name,
      dockData,
      journey.bikeDataFilter
    ),
    "scheduled_journey_initial_availability",
    "scheduled journey initial availability"
  );
}


function scheduledJourneyDockArrivalBody(dockName) {
  const resolvedDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "your dock";
  return `Welcome to ${resolvedDockName}!`;
}

function scheduledJourneyWatchingDestinationBody(dockName) {
  const resolvedDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "your destination dock";
  return `Now watching spaces at ${resolvedDockName}`;
}

function scheduledJourneyDestinationAvailabilityBody(dockName, dockData) {
  const resolvedDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "Destination dock";
  const spaces = sanitizeThresholdValue(dockData?.emptySpaces);
  return `${resolvedDockName}: ${spaces} ${spaces === 1 ? "space" : "spaces"} available`;
}

async function sendScheduledJourneyTransitionPushes(
  journey,
  destinationDock,
  options = {}
) {
  const deviceToken = normalizeApnsDeviceToken(journey.deviceToken);
  if (!deviceToken) return null;

  const buildType = journey.buildType === "production" ? "production" : "development";
  const startDock = journey.startDock || journey.activeRun;
  const arrivalDockName = startDock?.name || startDock?.dockName;
  const destinationDockName = destinationDock?.name || destinationDock?.dockName;
  const results = [];

  if (options.includeStartArrivalNotification !== false) {
    try {
      results.push(
        await sendAlertPush(
          deviceToken,
          buildType,
          "Dock arrival",
          scheduledJourneyDockArrivalBody(arrivalDockName),
          "scheduled_journey_start_arrival",
          "scheduled journey start arrival",
          {
            customPayload: {
              journeyId: journey._id?.toString?.() || null,
              dockId: startDock?.id || startDock?.dockId || null,
              dockName: arrivalDockName || null,
            },
          }
        )
      );
    } catch (err) {
      logger.warn(`Failed to send scheduled journey start-arrival push: ${err.message}`);
    }
  }

  try {
    results.push(
      await sendAlertPush(
        deviceToken,
        buildType,
        "Scheduled journey",
        scheduledJourneyWatchingDestinationBody(destinationDockName),
        "scheduled_journey_destination_watch",
        "scheduled journey destination watch",
        {
          customPayload: {
            journeyId: journey._id?.toString?.() || null,
            dockId: destinationDock?.id || destinationDock?.dockId || null,
            dockName: destinationDockName || null,
          },
        }
      )
    );
  } catch (err) {
    logger.warn(`Failed to send scheduled journey destination-watch push: ${err.message}`);
  }

  return results;
}

async function sendScheduledJourneyDestinationAvailabilityPushForSession(session, dockId, dockName, dockData) {
  const deviceToken = normalizeApnsDeviceToken(session?.deviceToken);
  if (!deviceToken) return null;

  return sendAlertPush(
    deviceToken,
    session.buildType === "production" ? "production" : "development",
    "Scheduled journey",
    scheduledJourneyDestinationAvailabilityBody(dockName, dockData),
    "scheduled_journey_destination_availability",
    "scheduled journey destination availability",
    {
      customPayload: {
        journeyId: session.scheduledJourneyId || null,
        dockId,
        dockName,
      },
    }
  );
}

async function sendAlertPush(
  deviceToken,
  buildType,
  title,
  body,
  event,
  logLabel,
  options = {}
) {
  const payloadBody = {
    aps: {
      alert: {
        title,
        body,
      },
      sound: "default",
    },
  };

  if (
    typeof options.category === "string" &&
    options.category.trim()
  ) {
    payloadBody.aps.category = options.category.trim();
  }

  if (options.customPayload && typeof options.customPayload === "object") {
    Object.assign(payloadBody, options.customPayload);
  }

  const payload = JSON.stringify(payloadBody);

  try {
    const result = await sendApnsRequestWithFallback(
      deviceToken,
      buildType,
      payload,
      (token, authToken) => ({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${authToken}`,
        "apns-topic": APNS_BACKGROUND_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      }),
      logLabel
    );
    recordPushEvent({
      target: deviceToken,
      channel: "notification",
      type: event,
      title,
      body,
      result: "ok",
      status: result.statusCode,
      apnsEnv: result.buildType,
    });
    apnsPushesTotal.inc({ event, build_type: result.buildType, status: "success" });
    return { status: result.statusCode, buildType: result.buildType };
  } catch (err) {
    const metricBuildType = err?.apns?.buildType || buildType;
    const statusCode = err?.apns?.statusCode ?? "unknown";
    const responseData = err?.apns?.responseData || err.message;
    recordPushEvent({
      target: deviceToken,
      channel: "notification",
      type: event,
      title,
      body,
      result: "error",
      status: statusCode,
      error: responseData,
      apnsEnv: metricBuildType,
    });
    apnsPushesTotal.inc({ event, build_type: metricBuildType, status: "failure" });
    logger.error(
      `${logLabel} push failed (${statusCode}): ${responseData} [token: ${deviceToken.substring(0, 8)}...]`
    );
    throw err;
  }
}

async function sendAvailabilityAlertPush(
  deviceToken,
  buildType,
  alertBody,
  dockId,
  dockName
) {
  const sanitizedDockName = sanitizeDockName(dockName);
  return sendAlertPush(
    deviceToken,
    buildType,
    "Dock availability update",
    alertBody,
    "availability_alert",
    "availability alert",
    {
      category: LIVE_ACTIVITY_ALERT_CATEGORY,
      customPayload: {
        dockId,
        dockName: sanitizedDockName || dockId,
      },
    }
  );
}

async function sendArrivalConfirmationPush(deviceToken, buildType, dockName) {
  const resolvedDockName =
    typeof dockName === "string" && dockName.trim() ? dockName.trim() : "your dock";
  return sendAlertPush(
    deviceToken,
    buildType,
    "Dock arrival",
    `Welcome to ${resolvedDockName}!`,
    "arrival_confirmation",
    "arrival confirmation"
  );
}

// ── Silent Background Push (complication refresh) ─────────────────────
// Sends a content-available:1 push to wake the iOS app so it can fetch
// fresh dock data and relay it to the watch via transferCurrentComplicationUserInfo.
// Background pushes MUST use apns-priority: 5 (not 10).
async function sendBackgroundPush(deviceToken, buildType) {
  const payload = JSON.stringify({ aps: { "content-available": 1 } });

  try {
    const result = await sendApnsRequestWithFallback(
      deviceToken,
      buildType,
      payload,
      (token, authToken) => ({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${authToken}`,
        "apns-topic": APNS_BACKGROUND_TOPIC,
        "apns-push-type": "background",
        "apns-priority": "5", // MUST be 5 for background pushes
        "apns-expiration": "0", // Don't deliver stale wake-ups
        "content-type": "application/json",
      }),
      "background"
    );
    recordPushEvent({
      target: deviceToken,
      channel: "background",
      type: "complication_refresh",
      result: "ok",
      status: result.statusCode,
      apnsEnv: result.buildType,
    });
    complicationPushesTotal.inc({ build_type: result.buildType, status: "success" });
    return { status: result.statusCode, buildType: result.buildType };
  } catch (err) {
    const metricBuildType = err?.apns?.buildType || buildType;
    const statusCode = err?.apns?.statusCode ?? "unknown";
    const responseData = err?.apns?.responseData || err.message;
    recordPushEvent({
      target: deviceToken,
      channel: "background",
      type: "complication_refresh",
      result: "error",
      status: statusCode,
      error: responseData,
      apnsEnv: metricBuildType,
    });
    complicationPushesTotal.inc({ build_type: metricBuildType, status: "failure" });
    logger.error(
      `Background push failed (${statusCode}): ${responseData} [token: ${deviceToken.substring(0, 8)}...]`
    );
    throw err;
  }
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
  let didUpdateBuildTypes = false;

  await Promise.all(
    Array.from(complicationTokens.entries()).map(async ([deviceToken, metadata]) => {
      const currentBuildType = metadata.buildType;
      try {
        const result = await sendBackgroundPush(deviceToken, currentBuildType);
        if (result.buildType !== currentBuildType) {
          metadata.buildType = result.buildType;
          didUpdateBuildTypes = true;
          logger.info(
            `Updated complication token environment to ${result.buildType}: ${deviceToken.substring(0, 8)}...`
          );
        }
      } catch (err) {
        // Remove tokens that APNs has flagged as bad
        if (isApnsTokenInvalidError(err)) {
          staleTokens.push(deviceToken);
          logger.info(`Removing stale complication token: ${deviceToken.substring(0, 8)}...`);
        }
      }
    })
  );

  for (const token of staleTokens) complicationTokens.delete(token);
  if (staleTokens.length > 0 || didUpdateBuildTypes) saveComplicationTokens();
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
      const staleLiveActivityTokens = new Set();
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
          const sessionDeviceToken = session.deviceToken;

          const dedupeKey = `${sessionDeviceToken}:${primaryDisplay}:${alertMessage}`;
          if (sentAlerts.has(dedupeKey)) continue;
          sentAlerts.add(dedupeKey);

          availabilityAlertPromises.push(
            sendAvailabilityAlertPush(
              sessionDeviceToken,
              session.buildType,
              alertMessage,
              dockId,
              data.dockName
            )
              .then((result) => {
                if (result.buildType !== session.buildType) {
                  session.buildType = result.buildType;
                  logger.info(
                    `Updated live activity session environment to ${result.buildType} for alert token ${sessionDeviceToken.substring(0, 8)}...`
                  );
                }
              })
              .catch((err) => {
                if (isApnsTokenInvalidError(err)) {
                  session.deviceToken = null;
                  logger.info(
                    `Cleared stale availability alert token: ${sessionDeviceToken.substring(0, 8)}...`
                  );
                }
                logger.error(
                  `Failed to send availability alert to ${sessionDeviceToken.substring(0, 8)}...:`,
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
          sendApnsPush(pushToken, contentState, "update", session.buildType)
            .then((result) => {
              if (result.buildType !== session.buildType) {
                session.buildType = result.buildType;
                logger.info(
                  `Updated live activity session environment to ${result.buildType} for ${pushToken.substring(0, 8)}...`
                );
              }
            })
            .catch((err) => {
              if (isApnsTokenInvalidError(err)) {
                staleLiveActivityTokens.add(pushToken);
              }
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

      if (staleLiveActivityTokens.size > 0) {
        let removedCount = 0;
        for (const staleToken of staleLiveActivityTokens) {
          if (poller.tokens.delete(staleToken)) {
            removedCount++;
            logger.info(
              `Removing stale live activity token after APNS rejection: ${staleToken.substring(0, 8)}...`
            );
          }
        }
        if (removedCount > 0) {
          for (let i = 0; i < removedCount; i++) {
            liveActivitiesEnded.inc({ reason: "error" });
          }
          updateLiveActivitiesActiveGauge();
        }
      }

      if (poller.tokens.size === 0) {
        stopPollingForDock(dockId);
        return;
      }
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

async function sendEndPushForSession(pushToken, session, lastData) {
  const contentState = contentStateWithAlternatives(lastData, session);
  const result = await sendApnsPush(pushToken, contentState, "end", session.buildType);
  if (result.buildType !== session.buildType) {
    session.buildType = result.buildType;
    logger.info(
      `Updated live activity session environment to ${result.buildType} for ${pushToken.substring(0, 8)}...`
    );
  }
}

async function endTrackedSessionsForDock(dockId, matcher, reason) {
  const poller = dockPollers.get(dockId);
  if (!poller) {
    return { endedCount: 0, remainingCount: 0 };
  }

  const matchingSessions = [];
  for (const [pushToken, session] of poller.tokens) {
    if (!matcher(pushToken, session)) continue;
    matchingSessions.push([pushToken, session]);
  }

  if (matchingSessions.length === 0) {
    return { endedCount: 0, remainingCount: poller.tokens.size };
  }

  const lastData = poller.lastData || {
    standardBikes: 0,
    eBikes: 0,
    emptySpaces: 0,
  };

  let endedCount = 0;

  for (const [pushToken, session] of matchingSessions) {
    try {
      await sendEndPushForSession(pushToken, session, lastData);
    } catch (err) {
      logger.error(`Failed to send end push:`, err.message);
    }

    if (poller.tokens.delete(pushToken)) {
      endedCount += 1;
      liveActivitiesEnded.inc({ reason });
    }
  }

  if (poller.tokens.size === 0) {
    stopPollingForDock(dockId);
  }

  updateLiveActivitiesActiveGauge();

  return {
    endedCount,
    remainingCount: poller.tokens.size,
  };
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

const pushEventLog = [];
const backgroundLocationEventLog = [];

function appendDiagnosticJsonLine(kind, entry) {
  const date = new Date().toISOString().slice(0, 10);
  const filePath = path.join(LOG_DIR, `diagnostics-${date}.jsonl`);
  const payload = JSON.stringify({
    recordedAt: new Date().toISOString(),
    kind,
    ...entry,
  });
  fs.appendFile(filePath, payload + "\n", (err) => {
    if (err) {
      logger.warn(`Failed to write diagnostic log entry: ${err.message}`);
    }
  });
}

function appendBoundedLogEntry(log, entry, maxEntries) {
  log.unshift(entry);
  if (log.length > maxEntries) {
    log.length = maxEntries;
  }
}

function shortenIdentifier(value) {
  if (typeof value !== "string") return "unknown";
  const trimmed = value.trim();
  if (!trimmed) return "unknown";
  if (trimmed.length <= 12) return trimmed;
  return `${trimmed.substring(0, 8)}...${trimmed.substring(trimmed.length - 4)}`;
}

function resolveLogLimit(rawValue, fallback, max) {
  const parsedValue = Number(rawValue);
  if (!Number.isFinite(parsedValue) || parsedValue <= 0) {
    return fallback;
  }
  return Math.min(Math.trunc(parsedValue), max);
}

function recordPushEvent(entry) {
  const normalizedEntry = {
    sentAt: new Date().toISOString(),
    target: shortenIdentifier(entry.target),
    channel: entry.channel || "unknown",
    type: entry.type || "unknown",
    title: entry.title || null,
    body: entry.body || null,
    result: entry.result || "unknown",
    status: entry.status ?? null,
    error: entry.error || null,
    apnsEnv: entry.apnsEnv || "unknown",
    raw: entry.raw || null,
  };
  appendBoundedLogEntry(pushEventLog, normalizedEntry, MAX_PUSH_EVENT_LOG_ENTRIES);
  appendDiagnosticJsonLine("push_event", normalizedEntry);
}

function recordBackgroundLocationEvent(entry) {
  const normalizedEntry = {
    receivedAt: new Date().toISOString(),
    clientTimestamp:
      typeof entry.clientTimestamp === "string" && entry.clientTimestamp.trim()
        ? entry.clientTimestamp.trim()
        : null,
    deviceId: shortenIdentifier(entry.deviceId),
    event: entry.event || "unknown",
    appState: entry.appState || "unknown",
    backgroundRefreshStatus: entry.backgroundRefreshStatus || "unknown",
    dockId: entry.dockId || null,
    dockName: entry.dockName || null,
    distanceMeters:
      typeof entry.distanceMeters === "number" && Number.isFinite(entry.distanceMeters)
        ? entry.distanceMeters
        : null,
    horizontalAccuracyMeters:
      typeof entry.horizontalAccuracyMeters === "number" &&
      Number.isFinite(entry.horizontalAccuracyMeters)
        ? entry.horizontalAccuracyMeters
        : null,
    arrivalThresholdMeters:
      typeof entry.arrivalThresholdMeters === "number" &&
      Number.isFinite(entry.arrivalThresholdMeters)
        ? entry.arrivalThresholdMeters
        : null,
    authorizationStatus: entry.authorizationStatus || null,
    message: entry.message || null,
    raw: entry.raw || null,
  };
  appendBoundedLogEntry(
    backgroundLocationEventLog,
    normalizedEntry,
    MAX_BACKGROUND_LOCATION_EVENT_LOG_ENTRIES
  );
  appendDiagnosticJsonLine("client_event", normalizedEntry);
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
      latitude:
        typeof override.latitude === "number" ? override.latitude : null,
      longitude:
        typeof override.longitude === "number" ? override.longitude : null,
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
  <title>Dock Admin & Diagnostics</title>
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
    <h1>Dock Admin & Diagnostics</h1>
    <p class="muted">Set manual bikes/e-bikes/spaces values or override dock coordinates for a dock, then inspect recent push plus background-location diagnostics. Overrides affect <code>/Place/:dockId</code>, <code>/BikePoint</code>, and live activity polling.</p>

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
        <label>
          Latitude Override
          <input id="latitude" type="number" min="-90" max="90" step="0.000001" placeholder="Leave blank to use TfL latitude" />
        </label>
        <label>
          Longitude Override
          <input id="longitude" type="number" min="-180" max="180" step="0.000001" placeholder="Leave blank to use TfL longitude" />
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
            <th>Location Override</th>
            <th>Updated</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody id="overridesBody"></tbody>
      </table>
    </section>

    <section class="panel" style="margin-top: 14px;">
      <h2 style="margin: 0 0 4px; font-size: 18px;">Notification & Push Events</h2>
      <p class="muted" style="margin: 0 0 8px;">Last 20 APNs sends recorded in-memory, including live activity pushes, welcome alerts, and silent refresh pushes.</p>
      <table>
        <thead>
          <tr>
            <th>Sent At</th>
            <th>Target</th>
            <th>Channel</th>
            <th>Type</th>
            <th>Message</th>
            <th>Result</th>
            <th>Status</th>
            <th>APNS Env</th>
          </tr>
        </thead>
        <tbody id="pushEventsBody"></tbody>
      </table>
    </section>

    <section class="panel" style="margin-top: 14px;">
      <h2 style="margin: 0 0 4px; font-size: 18px;">Background Location Events</h2>
      <p class="muted" style="margin: 0 0 8px;">Last 100 client-reported location and arrival events. Compare client timestamp to received time to spot delayed uploads.</p>
      <table>
        <thead>
          <tr>
            <th>Received At</th>
            <th>Client Time</th>
            <th>Device</th>
            <th>Event</th>
            <th>App State</th>
            <th>BG Refresh</th>
            <th>Dock</th>
            <th>Distance</th>
            <th>Accuracy</th>
            <th>Threshold</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody id="backgroundLocationEventsBody"></tbody>
      </table>
    </section>
  </main>

  <script>
    const dockSearch = document.getElementById("dockSearch");
    const dockSelect = document.getElementById("dockSelect");
    const standardBikesInput = document.getElementById("standardBikes");
    const eBikesInput = document.getElementById("eBikes");
    const emptySpacesInput = document.getElementById("emptySpaces");
    const latitudeInput = document.getElementById("latitude");
    const longitudeInput = document.getElementById("longitude");
    const statusElement = document.getElementById("status");
    const selectionHint = document.getElementById("selectionHint");
    const overridesBody = document.getElementById("overridesBody");
    const pushEventsBody = document.getElementById("pushEventsBody");
    const backgroundLocationEventsBody = document.getElementById("backgroundLocationEventsBody");
    const normalizedPath = (window.location.pathname || "").replace(/\\/+$/, "");
    const adminBasePath = normalizedPath.endsWith("/admin") ? normalizedPath : "/admin";
    const apiBasePath = adminBasePath + "/api";

    let allDocks = [];
    let overridesByDockId = new Map();
    let filteredDocks = [];

    function escapeHtml(value) {
      return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
    }

    function formatNumber(value) {
      if (typeof value !== "number" || !Number.isFinite(value)) {
        return "—";
      }
      return value.toFixed(1);
    }

    function formatTimestamp(value) {
      if (!value) return "—";
      const parsed = new Date(value);
      if (Number.isNaN(parsed.getTime())) {
        return escapeHtml(value);
      }
      return escapeHtml(parsed.toLocaleString());
    }

    function dockLabel(dockId, dockName) {
      if (dockName && dockId) {
        return escapeHtml(dockName + " (" + dockId + ")");
      }
      return escapeHtml(dockName || dockId || "—");
    }

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
        latitudeInput.value =
          typeof override.latitude === "number" ? String(override.latitude) : "";
        longitudeInput.value =
          typeof override.longitude === "number" ? String(override.longitude) : "";
        selectionHint.textContent =
          "Editing override for " +
          selectedDock.commonName +
          ". TfL location: " +
          formatNumber(selectedDock.lat) +
          ", " +
          formatNumber(selectedDock.lon) +
          ".";
      } else {
        standardBikesInput.value = "0";
        eBikesInput.value = "0";
        emptySpacesInput.value = "0";
        latitudeInput.value = "";
        longitudeInput.value = "";
        selectionHint.textContent =
          "No override set for " +
          selectedDock.commonName +
          ". TfL location: " +
          formatNumber(selectedDock.lat) +
          ", " +
          formatNumber(selectedDock.lon) +
          ".";
      }
    }

    function renderOverridesTable() {
      const overrides = Array.from(overridesByDockId.values()).sort((a, b) =>
        a.dockId.localeCompare(b.dockId)
      );

      if (overrides.length === 0) {
        overridesBody.innerHTML = '<tr><td colspan="7">No active overrides.</td></tr>';
        return;
      }

      overridesBody.innerHTML = "";
      for (const override of overrides) {
        const dock = allDocks.find((item) => item.id === override.dockId);
        const dockLabel = dock
          ? dock.commonName + " (" + override.dockId + ")"
          : override.dockId;
        const locationOverride =
          typeof override.latitude === "number" && typeof override.longitude === "number"
            ? formatNumber(override.latitude) + ", " + formatNumber(override.longitude)
            : "—";

        const row = document.createElement("tr");
        row.innerHTML =
          "<td>" + dockLabel + "</td>" +
          "<td>" + override.standardBikes + "</td>" +
          "<td>" + override.eBikes + "</td>" +
          "<td>" + override.emptySpaces + "</td>" +
          "<td>" + escapeHtml(locationOverride) + "</td>" +
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

    function renderPushEventsTable(events) {
      if (!Array.isArray(events) || events.length === 0) {
        pushEventsBody.innerHTML = '<tr><td colspan="8">No push events recorded since server start.</td></tr>';
        return;
      }

      pushEventsBody.innerHTML = "";
      for (const event of events) {
        const messageParts = [];
        if (event.title) messageParts.push(event.title);
        if (event.body) messageParts.push(event.body);
        if (messageParts.length === 0 && event.error) messageParts.push(event.error);
        const message = messageParts.length > 0 ? messageParts.join(": ") : "—";

        const row = document.createElement("tr");
        row.innerHTML =
          "<td>" + formatTimestamp(event.sentAt) + "</td>" +
          "<td>" + escapeHtml(event.target || "—") + "</td>" +
          "<td>" + escapeHtml(event.channel || "—") + "</td>" +
          "<td>" + escapeHtml(event.type || "—") + "</td>" +
          "<td>" + escapeHtml(message) + "</td>" +
          "<td>" + escapeHtml(event.result || "—") + "</td>" +
          "<td>" + escapeHtml(event.status ?? "—") + "</td>" +
          "<td>" + escapeHtml(event.apnsEnv || "—") + "</td>";
        pushEventsBody.appendChild(row);
      }
    }

    async function loadPushEvents() {
      const response = await fetch(apiUrl("/push-events?limit=20"));
      if (!response.ok) {
        throw new Error("Could not load push events");
      }
      const payload = await response.json();
      renderPushEventsTable(payload.events || []);
    }

    function renderBackgroundLocationEventsTable(events) {
      if (!Array.isArray(events) || events.length === 0) {
        backgroundLocationEventsBody.innerHTML = '<tr><td colspan="11">No background location events recorded since server start.</td></tr>';
        return;
      }

      backgroundLocationEventsBody.innerHTML = "";
      for (const event of events) {
        const row = document.createElement("tr");
        row.innerHTML =
          "<td>" + formatTimestamp(event.receivedAt) + "</td>" +
          "<td>" + formatTimestamp(event.clientTimestamp) + "</td>" +
          "<td>" + escapeHtml(event.deviceId || "—") + "</td>" +
          "<td>" + escapeHtml(event.event || "—") + "</td>" +
          "<td>" + escapeHtml(event.appState || "—") + "</td>" +
          "<td>" + escapeHtml(event.backgroundRefreshStatus || "—") + "</td>" +
          "<td>" + dockLabel(event.dockId, event.dockName) + "</td>" +
          "<td>" + escapeHtml(formatNumber(event.distanceMeters)) + "</td>" +
          "<td>" + escapeHtml(formatNumber(event.horizontalAccuracyMeters)) + "</td>" +
          "<td>" + escapeHtml(formatNumber(event.arrivalThresholdMeters)) + "</td>" +
          "<td>" + escapeHtml(event.message || "—") + "</td>";
        backgroundLocationEventsBody.appendChild(row);
      }
    }

    async function loadBackgroundLocationEvents() {
      const response = await fetch(apiUrl("/background-location-events?limit=100"));
      if (!response.ok) {
        throw new Error("Could not load background location events");
      }
      const payload = await response.json();
      renderBackgroundLocationEventsTable(payload.events || []);
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
      const latitudeRaw = (latitudeInput.value || "").trim();
      const longitudeRaw = (longitudeInput.value || "").trim();

      if (
        body.standardBikes === null ||
        body.eBikes === null ||
        body.emptySpaces === null
      ) {
        setStatus("All values must be whole numbers greater than or equal to 0.", "error");
        return;
      }
      if ((latitudeRaw && !longitudeRaw) || (!latitudeRaw && longitudeRaw)) {
        setStatus("Provide both latitude and longitude, or leave both blank.", "error");
        return;
      }
      if (latitudeRaw && longitudeRaw) {
        body.latitude = latitudeRaw;
        body.longitude = longitudeRaw;
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
      Promise.all([loadDocks(), loadOverrides(), loadPushEvents(), loadBackgroundLocationEvents()])
        .then(() => setStatus("Reloaded dock data and diagnostics.", "ok"))
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

    Promise.all([loadDocks(), loadOverrides(), loadPushEvents(), loadBackgroundLocationEvents()])
      .then(() => setStatus("", ""))
      .catch((err) => setStatus(err.message, "error"));

    setInterval(() => {
      Promise.all([loadPushEvents(), loadBackgroundLocationEvents()]).catch(() => {});
    }, 15000);
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
          lat: Number(point.lat),
          lon: Number(point.lon),
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
    updateTflBikePointFreshness(bikePoints);
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

app.get(adminRoutePaths("/api/push-events"), (req, res) => {
  const limit = resolveLogLimit(req.query?.limit, 20, 100);
  res.json({
    count: pushEventLog.length,
    events: pushEventLog.slice(0, limit),
  });
});

app.get(adminRoutePaths("/api/background-location-events"), (req, res) => {
  const limit = resolveLogLimit(req.query?.limit, 100, 300);
  res.json({
    count: backgroundLocationEventLog.length,
    events: backgroundLocationEventLog.slice(0, limit),
  });
});

app.post(adminRoutePaths("/api/overrides"), (req, res) => {
  const dockId =
    typeof req.body?.dockId === "string" ? req.body.dockId.trim() : "";
  const standardBikes = normalizeNonNegativeInteger(req.body?.standardBikes);
  const eBikes = normalizeNonNegativeInteger(req.body?.eBikes);
  const emptySpaces = normalizeNonNegativeInteger(req.body?.emptySpaces);
  const latitude = parseOptionalCoordinate(req.body?.latitude, -90, 90);
  const longitude = parseOptionalCoordinate(req.body?.longitude, -180, 180);

  if (!dockId) {
    return res.status(400).json({ error: "dockId is required" });
  }
  if (standardBikes === null || eBikes === null || emptySpaces === null) {
    return res.status(400).json({
      error: "standardBikes, eBikes, and emptySpaces must be integers >= 0",
    });
  }
  if (latitude === null || longitude === null) {
    return res.status(400).json({
      error: "latitude must be between -90 and 90, and longitude between -180 and 180",
    });
  }
  if ((latitude === undefined) !== (longitude === undefined)) {
    return res.status(400).json({
      error: "latitude and longitude must be provided together",
    });
  }

  const override = {
    standardBikes,
    eBikes,
    emptySpaces,
    latitude: latitude ?? null,
    longitude: longitude ?? null,
    updatedAt: Date.now(),
  };
  dockOverrides.set(dockId, override);
  saveDockOverrides();

  logger.info(
    `Set dock override for ${dockId}: bikes=${standardBikes}, eBikes=${eBikes}, spaces=${emptySpaces}, lat=${override.latitude ?? "default"}, lon=${override.longitude ?? "default"}`
  );

  res.json({
    success: true,
    override: {
      dockId,
      standardBikes,
      eBikes,
      emptySpaces,
      latitude: override.latitude,
      longitude: override.longitude,
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

app.post("/scheduled-journeys/device/register", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  if (!deviceId) {
    return res.status(400).json({ error: "Missing required deviceId" });
  }

  const pushToStartToken = normalizeApnsDeviceToken(req.body?.pushToStartToken);
  const deviceToken = normalizeApnsDeviceToken(req.body?.deviceToken);
  const buildType = req.body?.buildType === "production" ? "production" : "development";
  const timezone = sanitizeTimeZone(req.body?.timezone) || "Europe/London";
  const bikeDataFilter = sanitizeBikeDataFilter(req.body?.bikeDataFilter);

  const update = {
    deviceId,
    buildType,
    timezone,
    bikeDataFilter,
    updatedAt: new Date(),
  };
  if (pushToStartToken) update.pushToStartToken = pushToStartToken;
  if (deviceToken) update.deviceToken = deviceToken;

  await collection.updateMany(
    { deviceId, deletedAt: { $exists: false } },
    { $set: update }
  );

  res.json({ success: true, deviceId, hasPushToStartToken: !!pushToStartToken });
});

app.get("/scheduled-journeys", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  if (!deviceId) {
    return res.status(400).json({ error: "Missing required deviceId" });
  }

  const journeys = await collection
    .find({ deviceId, deletedAt: { $exists: false } })
    .sort({ createdAt: 1 })
    .toArray();

  res.json({ success: true, journeys: journeys.map(serializeScheduledJourney) });
});

app.post("/scheduled-journeys", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  if (!deviceId) {
    return res.status(400).json({ error: "Missing required deviceId" });
  }

  const existingCount = await collection.countDocuments({
    deviceId,
    deletedAt: { $exists: false },
  });
  if (existingCount >= MAX_SCHEDULED_JOURNEYS_PER_DEVICE) {
    return res.status(409).json({ error: "You can add up to 5 scheduled journeys" });
  }

  const sanitized = sanitizeScheduledJourneyPayload(req.body);
  if (sanitized.error) {
    return res.status(400).json({ error: sanitized.error });
  }

  const now = new Date();
  const doc = {
    ...sanitized.value,
    deviceId,
    deviceToken: normalizeApnsDeviceToken(req.body?.deviceToken) || null,
    pushToStartToken: normalizeApnsDeviceToken(req.body?.pushToStartToken) || null,
    buildType: req.body?.buildType === "production" ? "production" : "development",
    bikeDataFilter: sanitized.value.bikeDataFilter,
    activeRun: null,
    pausedRunKeys: [],
    createdAt: now,
    updatedAt: now,
  };
  const result = await collection.insertOne(doc);
  const inserted = await collection.findOne({ _id: result.insertedId });
  res.status(201).json({ success: true, journey: serializeScheduledJourney(inserted) });
});

app.put("/scheduled-journeys/:id", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  if (!deviceId || !ObjectId.isValid(journeyId)) {
    return res.status(400).json({ error: "Missing deviceId or invalid journey id" });
  }

  const sanitized = sanitizeScheduledJourneyPayload(req.body);
  if (sanitized.error) {
    return res.status(400).json({ error: sanitized.error });
  }

  const result = await collection.findOneAndUpdate(
    { _id: new ObjectId(journeyId), deviceId, deletedAt: { $exists: false } },
    { $set: { ...sanitized.value, updatedAt: new Date() } },
    { returnDocument: "after" }
  );
  if (!result) return res.status(404).json({ error: "Scheduled journey not found" });
  res.json({ success: true, journey: serializeScheduledJourney(result) });
});

app.delete("/scheduled-journeys/:id", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  if (!deviceId || !ObjectId.isValid(journeyId)) {
    return res.status(400).json({ error: "Missing deviceId or invalid journey id" });
  }

  const result = await collection.findOneAndUpdate(
    { _id: new ObjectId(journeyId), deviceId, deletedAt: { $exists: false } },
    { $set: { deletedAt: new Date(), activeRun: null, updatedAt: new Date() } },
    { returnDocument: "after" }
  );
  if (!result) return res.status(404).json({ error: "Scheduled journey not found" });
  res.json({ success: true });
});

app.post("/scheduled-journeys/:id/activate", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  if (!deviceId || !ObjectId.isValid(journeyId)) {
    return res.status(400).json({ error: "Missing deviceId or invalid journey id" });
  }

  const journey = await collection.findOne({
    _id: new ObjectId(journeyId),
    deviceId,
    deletedAt: { $exists: false },
  });
  if (!journey) return res.status(404).json({ error: "Scheduled journey not found" });

  const runKey = scheduledRunKey(journey);
  if (req.body?.remoteStart !== false) {
    try {
      const arbitration = await prepareScheduledJourneyStart(journey, "manual");
      if (!arbitration.canStart) {
        return res.status(409).json({
          success: false,
          error: "A journey is already in progress",
          journey: serializeScheduledJourney(journey),
        });
      }
    } catch (err) {
      logger.warn(`Manual scheduled journey arbitration failed: ${err.message}`);
    }
  }

  await collection.updateOne(
    { _id: journey._id },
    {
      $set: {
        activeRun: {
          phase: "start",
          dockId: journey.startDock.id,
          dockName: journey.startDock.name,
          startedAt: new Date(),
          runKey,
          manuallyActivated: true,
        },
        updatedAt: new Date(),
      },
      $pull: { pausedRunKeys: runKey },
    }
  );

  if (req.body?.remoteStart !== false) {
    try {
      await sendScheduledJourneyStartPush({ ...journey, activeRun: { runKey } }, "manual");
    } catch (err) {
      logger.warn(`Manual scheduled journey push-start failed: ${err.message}`);
    }
  }

  const updated = await collection.findOne({ _id: journey._id });
  res.json({ success: true, journey: serializeScheduledJourney(updated) });
});

app.post("/scheduled-journeys/:id/stop", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  if (!deviceId || !ObjectId.isValid(journeyId)) {
    return res.status(400).json({ error: "Missing deviceId or invalid journey id" });
  }

  const journey = await collection.findOne({
    _id: new ObjectId(journeyId),
    deviceId,
    deletedAt: { $exists: false },
  });
  if (!journey) return res.status(404).json({ error: "Scheduled journey not found" });

  const runKey = journey.activeRun?.runKey || scheduledRunKey(journey);
  await collection.updateOne(
    { _id: journey._id },
    {
      $set: { activeRun: null, updatedAt: new Date() },
      $addToSet: { pausedRunKeys: runKey },
    }
  );

  for (const dockId of [journey.startDock.id, journey.endDock.id]) {
    await endTrackedSessionsForDock(
      dockId,
      (_pushToken, session) =>
        session.deviceToken === journey.deviceToken ||
        session.scheduledJourneyId === journey._id.toString(),
      "scheduled_stop"
    );
  }

  const updated = await collection.findOne({ _id: journey._id });
  res.json({ success: true, journey: serializeScheduledJourney(updated) });
});

app.post("/scheduled-journeys/:id/phase", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  const phase = req.body?.phase === "end" ? "end" : req.body?.phase === "start" ? "start" : null;
  const transitionSource =
    req.body?.transitionSource === "arrival" ? "arrival" :
      req.body?.transitionSource === "manual" ? "manual" : null;
  if (!deviceId || !ObjectId.isValid(journeyId) || !phase) {
    return res.status(400).json({ error: "Missing deviceId, phase, or invalid journey id" });
  }

  const journey = await collection.findOne({
    _id: new ObjectId(journeyId),
    deviceId,
    deletedAt: { $exists: false },
  });
  if (!journey) return res.status(404).json({ error: "Scheduled journey not found" });

  const dock = phase === "end" ? journey.endDock : journey.startDock;
  const result = await collection.findOneAndUpdate(
    { _id: journey._id },
    {
      $set: {
        activeRun: {
          phase,
          dockId: dock.id,
          dockName: dock.name,
          startedAt: journey.activeRun?.startedAt || new Date(),
          runKey: journey.activeRun?.runKey || scheduledRunKey(journey),
        },
        updatedAt: new Date(),
      },
    },
    { returnDocument: "after" }
  );

  appendDiagnosticJsonLine("scheduled_journey_phase_update", {
    journeyId,
    deviceId: shortenIdentifier(deviceId),
    phase,
    transitionSource,
    dockId: dock.id,
    dockName: dock.name,
  });

  if (phase === "end") {
    await sendScheduledJourneyTransitionPushes(journey, dock, {
      includeStartArrivalNotification: transitionSource !== "manual",
    });
  }

  res.json({ success: true, journey: serializeScheduledJourney(result) });
});

app.post("/scheduled-journeys/:id/complete", async (req, res) => {
  const collection = await requireScheduledJourneysCollection(res);
  if (!collection) return;

  const deviceId = deviceIdFromRequest(req);
  const journeyId = req.params.id;
  if (!deviceId || !ObjectId.isValid(journeyId)) {
    return res.status(400).json({ error: "Missing deviceId or invalid journey id" });
  }

  const result = await collection.findOneAndUpdate(
    { _id: new ObjectId(journeyId), deviceId, deletedAt: { $exists: false } },
    { $set: { activeRun: null, updatedAt: new Date() } },
    { returnDocument: "after" }
  );
  if (!result) return res.status(404).json({ error: "Scheduled journey not found" });
  res.json({ success: true, journey: serializeScheduledJourney(result) });
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
    scheduledJourneyId,
    scheduledJourneyPhase,
    adHocJourneyId,
    standardBikes,
    eBikes,
    emptySpaces,
    activeDockId,
    activeDockName,
    activeDockAlias,
    activeJourneyPhase,
  } = req.body;
  const normalizedPushToken = normalizeApnsDeviceToken(pushToken);

  if (!dockId || !normalizedPushToken || !buildType) {
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
  const now = Date.now();

  if (!deviceToken && req.headers["x-device-token"]) {
    logger.warn(
      `Ignoring invalid APNs device token for live activity start (dock=${dockId})`
    );
  }

  // Register the token for this dock
  if (!dockPollers.has(dockId)) {
    dockPollers.set(dockId, {
      interval: null,
      lastData: null,
      tokens: new Map(),
    });
  }

  const poller = dockPollers.get(dockId);
  const seededData = {
    dockName: normalizedDockName || dockId,
    standardBikes: sanitizeThresholdValue(standardBikes),
    eBikes: sanitizeThresholdValue(eBikes),
    emptySpaces: sanitizeThresholdValue(emptySpaces),
  };
  const hasSeededAvailability =
    standardBikes !== undefined || eBikes !== undefined || emptySpaces !== undefined;
  if (hasSeededAvailability && !poller.lastData) {
    poller.lastData = seededData;
    logger.info(
      `Seeded live activity session for dock ${dockId}: bikes=${seededData.standardBikes}, eBikes=${seededData.eBikes}, spaces=${seededData.emptySpaces}`
    );
  }
  const existingSessionForPushToken = poller.tokens.get(normalizedPushToken);
  let startedAt = now;
  let hardStopAt = startedAt + HARD_NOTIFICATION_CUTOFF_MS;

  if (existingSessionForPushToken) {
    startedAt = sessionStartedAtMs(existingSessionForPushToken);
    hardStopAt = sessionHardStopAtMs(existingSessionForPushToken);
  } else if (deviceToken) {
    const matchingDeviceSessions = [];
    for (const [existingPushToken, existingSession] of poller.tokens) {
      if (existingSession.deviceToken !== deviceToken) continue;
      if (existingSession.buildType !== buildType) continue;

      const existingExpiresAtMs = sessionExpiresAtMs(existingSession);
      if (existingExpiresAtMs <= now) {
        // Clean up stale tokens first so a new session can start cleanly.
        poller.tokens.delete(existingPushToken);
        continue;
      }

      matchingDeviceSessions.push({
        pushToken: existingPushToken,
        session: existingSession,
      });
    }

    if (matchingDeviceSessions.length > 0) {
      startedAt = matchingDeviceSessions.reduce(
        (earliestStartAt, item) =>
          Math.min(earliestStartAt, sessionStartedAtMs(item.session)),
        now
      );
      hardStopAt = matchingDeviceSessions.reduce(
        (earliestHardStopAt, item) =>
          Math.min(earliestHardStopAt, sessionHardStopAtMs(item.session)),
        startedAt + HARD_NOTIFICATION_CUTOFF_MS
      );

      for (const item of matchingDeviceSessions) {
        if (item.pushToken === normalizedPushToken) continue;
        poller.tokens.delete(item.pushToken);
      }
    }
  }

  const effectiveExpiresAtMs = sessionExpiresAtMs({
    startedAt,
    hardStopAt,
    expiryMs,
  });
  const effectiveRemainingSeconds = Math.max(
    0,
    Math.floor((effectiveExpiresAtMs - now) / 1000)
  );

  logger.info(
    `Starting live activity: dock=${dockId}, build=${buildType}, primaryDisplay=${normalizedPrimaryDisplay}, minimumThreshold=${activeMinimumThreshold}, expires in ${effectiveRemainingSeconds}s`
  );
  logger.info(`  pushToken: ${normalizedPushToken} (alternatives: ${normalizedAlternatives.length})`);
  const normalizedScheduledJourneyPhase = scheduledJourneyPhaseFromValues(
    scheduledJourneyPhase,
    activeJourneyPhase
  );

  poller.tokens.set(normalizedPushToken, {
    buildType,
    startedAt,
    hardStopAt,
    expiryMs,
    dockName: normalizedDockName,
    alternatives: normalizedAlternatives,
    primaryDisplay: normalizedPrimaryDisplay,
    minimumThresholds: normalizedMinimumThresholds,
    deviceToken,
    scheduledJourneyId:
      typeof scheduledJourneyId === "string" && ObjectId.isValid(scheduledJourneyId)
        ? scheduledJourneyId
        : null,
    scheduledJourneyPhase: normalizedScheduledJourneyPhase,
    adHocJourneyId:
      typeof adHocJourneyId === "string" && adHocJourneyId.trim()
        ? adHocJourneyId.trim().slice(0, 128)
        : null,
    activeDockId:
      typeof activeDockId === "string" && activeDockId.trim() ? activeDockId.trim() : dockId,
    activeDockName:
      typeof activeDockName === "string" && activeDockName.trim()
        ? activeDockName.trim()
        : normalizedDockName || dockId,
    activeDockAlias:
      typeof activeDockAlias === "string" && activeDockAlias.trim() ? activeDockAlias.trim() : null,
  });

  appendDiagnosticJsonLine("live_activity_session_registered", {
    dockId,
    dockName: normalizedDockName || dockId,
    pushToken: shortenIdentifier(normalizedPushToken),
    deviceToken: shortenIdentifier(deviceToken),
    buildType,
    primaryDisplay: normalizedPrimaryDisplay,
    alternativesCount: normalizedAlternatives.length,
    scheduledJourneyId:
      typeof scheduledJourneyId === "string" && ObjectId.isValid(scheduledJourneyId)
        ? scheduledJourneyId
        : null,
    scheduledJourneyPhase: normalizedScheduledJourneyPhase,
    adHocJourneyId:
      typeof adHocJourneyId === "string" && adHocJourneyId.trim()
        ? adHocJourneyId.trim().slice(0, 128)
        : null,
    seededAvailability: hasSeededAvailability ? seededData : null,
    activeTokenCountForDock: poller.tokens.size,
    expiresAt: new Date(effectiveExpiresAtMs).toISOString(),
  });

  if (
    scheduledJourneysCollection &&
    typeof scheduledJourneyId === "string" &&
    ObjectId.isValid(scheduledJourneyId) &&
    normalizedScheduledJourneyPhase
  ) {
    const scheduledJourneyObjectId = new ObjectId(scheduledJourneyId);
    scheduledJourneysCollection.findOne(
      { _id: scheduledJourneyObjectId, deletedAt: { $exists: false } },
      { projection: { startDock: 1, endDock: 1, activeRun: 1, timezone: 1, startTime: 1 } }
    ).then((journey) => {
      if (!journey) return null;
      if (normalizedScheduledJourneyPhase === "start" && journey.activeRun?.phase === "end") {
        logger.warn(
          `Skipping stale start-phase registration for scheduled journey ${scheduledJourneyId} because it is already watching the destination dock`
        );
        return null;
      }
      if (normalizedScheduledJourneyPhase === "end" && !journey.activeRun?.phase) {
        logger.warn(
          `Skipping stale end-phase registration for scheduled journey ${scheduledJourneyId} because it is already complete`
        );
        return null;
      }
      const dock = normalizedScheduledJourneyPhase === "end" ? journey.endDock : journey.startDock;
      return scheduledJourneysCollection.updateOne(
        { _id: scheduledJourneyObjectId, deletedAt: { $exists: false } },
        {
          $set: {
            activeRun: {
              phase: normalizedScheduledJourneyPhase,
              dockId: dock?.id || dockId,
              dockName: dock?.name || normalizedDockName || dockId,
              startedAt: journey.activeRun?.startedAt || new Date(),
              runKey: journey.activeRun?.runKey || req.body?.scheduledRunKey || scheduledRunKey(journey),
            },
            updatedAt: new Date(),
          },
        }
      );
    }).catch((err) => {
      logger.warn(`Failed to mark scheduled journey active: ${err.message}`);
    });
  } else if (
    scheduledJourneysCollection &&
    typeof scheduledJourneyId === "string" &&
    ObjectId.isValid(scheduledJourneyId)
  ) {
    logger.warn(
      `Skipping scheduled journey active-run update for ${scheduledJourneyId} because live activity registration did not include a journey phase`
    );
  }

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
    expiresIn: `${effectiveRemainingSeconds} seconds`,
  });
});

app.post("/live-activity/session/update", async (req, res) => {
  const {
    dockId,
    targetDockId,
    pushToken,
    dockName,
    primaryDisplay,
    minimumThresholds,
    alternatives,
    scheduledJourneyPhase,
    standardBikes,
    eBikes,
    emptySpaces,
    activeDockId,
    activeDockName,
    activeDockAlias,
    activeJourneyPhase,
  } = req.body;
  const normalizedPushToken = normalizeApnsDeviceToken(pushToken);
  const resolvedTargetDockId =
    typeof targetDockId === "string" && targetDockId.trim()
      ? targetDockId.trim()
      : typeof activeDockId === "string" && activeDockId.trim()
        ? activeDockId.trim()
        : dockId;

  if (!dockId || !normalizedPushToken) {
    return res
      .status(400)
      .json({ error: "Missing required fields: dockId, pushToken" });
  }

  const sourcePoller = dockPollers.get(dockId);
  if (!sourcePoller) {
    return res.status(404).json({ error: "Live activity session not found for dock" });
  }

  const session = sourcePoller.tokens.get(normalizedPushToken);
  if (!session) {
    return res.status(404).json({ error: "Live activity session token not found" });
  }

  if (primaryDisplay !== undefined) {
    session.primaryDisplay = sanitizePrimaryDisplay(primaryDisplay);
  }

  if (minimumThresholds !== undefined) {
    session.minimumThresholds = sanitizeMinimumThresholds(minimumThresholds);
  }

  if (alternatives !== undefined) {
    session.alternatives = sanitizeAlternatives(alternatives);
  }

  if (dockName !== undefined) {
    session.dockName = sanitizeDockName(dockName);
  }

  const normalizedScheduledJourneyPhase = scheduledJourneyPhaseFromValues(
    scheduledJourneyPhase,
    activeJourneyPhase
  );
  if (normalizedScheduledJourneyPhase) {
    session.scheduledJourneyPhase = normalizedScheduledJourneyPhase;
  }

  session.activeDockId = resolvedTargetDockId;
  session.activeDockName =
    typeof activeDockName === "string" && activeDockName.trim()
      ? activeDockName.trim()
      : sanitizeDockName(dockName) || session.dockName || resolvedTargetDockId;
  session.activeDockAlias =
    typeof activeDockAlias === "string" && activeDockAlias.trim()
      ? activeDockAlias.trim()
      : null;

  const deviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  if (deviceToken) {
    session.deviceToken = deviceToken;
  } else if (req.headers["x-device-token"]) {
    logger.warn(
      `Ignoring invalid APNs device token for live activity session update (dock=${dockId})`
    );
  }

  const hasSeededAvailability =
    standardBikes !== undefined || eBikes !== undefined || emptySpaces !== undefined;
  const seededData = {
    dockName: session.activeDockName || session.dockName || resolvedTargetDockId,
    standardBikes: sanitizeThresholdValue(standardBikes),
    eBikes: sanitizeThresholdValue(eBikes),
    emptySpaces: sanitizeThresholdValue(emptySpaces),
  };

  let targetPoller = sourcePoller;
  if (resolvedTargetDockId !== dockId) {
    sourcePoller.tokens.delete(normalizedPushToken);
    if (!dockPollers.has(resolvedTargetDockId)) {
      dockPollers.set(resolvedTargetDockId, {
        interval: null,
        lastData: null,
        tokens: new Map(),
      });
    }
    targetPoller = dockPollers.get(resolvedTargetDockId);
    targetPoller.tokens.set(normalizedPushToken, session);
    if (sourcePoller.tokens.size === 0) {
      stopPollingForDock(dockId);
    }
    startPollingForDock(resolvedTargetDockId);
  }

  if (hasSeededAvailability) {
    targetPoller.lastData = seededData;
  }

  const resolvedPrimaryDisplay = sanitizePrimaryDisplay(session.primaryDisplay);
  const resolvedMinimumThreshold = minimumThresholdForDisplay(
    session.minimumThresholds,
    resolvedPrimaryDisplay
  );

  logger.info(
    `Updated live activity session: dock=${dockId}, targetDock=${resolvedTargetDockId}, token=${normalizedPushToken.substring(0, 8)}..., primaryDisplay=${resolvedPrimaryDisplay}, minimumThreshold=${resolvedMinimumThreshold}`
  );

  appendDiagnosticJsonLine("live_activity_session_updated", {
    dockId,
    targetDockId: resolvedTargetDockId,
    dockName: session.activeDockName || session.dockName || resolvedTargetDockId,
    pushToken: shortenIdentifier(normalizedPushToken),
    primaryDisplay: resolvedPrimaryDisplay,
    scheduledJourneyPhase: session.scheduledJourneyPhase || null,
    migrated: resolvedTargetDockId !== dockId,
    seededAvailability: hasSeededAvailability ? seededData : null,
  });

  if (hasSeededAvailability) {
    try {
      const contentState = contentStateWithAlternatives(seededData, session);
      const result = await sendApnsPush(
        normalizedPushToken,
        contentState,
        "update",
        session.buildType
      );
      if (result.buildType !== session.buildType) {
        session.buildType = result.buildType;
      }
    } catch (err) {
      logger.error(
        `Failed to send immediate migrated live activity update to ${normalizedPushToken.substring(0, 8)}...:`,
        err.message
      );
    }
  }

  if (
    resolvedTargetDockId !== dockId &&
    session.scheduledJourneyPhase === "end" &&
    hasSeededAvailability &&
    !session.destinationAvailabilitySentAt
  ) {
    try {
      await sendScheduledJourneyDestinationAvailabilityPushForSession(
        session,
        resolvedTargetDockId,
        session.activeDockName || session.dockName || resolvedTargetDockId,
        seededData
      );
      session.destinationAvailabilitySentAt = Date.now();
    } catch (err) {
      logger.warn(
        `Failed to send scheduled journey destination availability push: ${err.message}`
      );
    }
  }

  updateLiveActivitiesActiveGauge();

  res.json({
    success: true,
    dockId: resolvedTargetDockId,
    dockName:
      session.activeDockName ||
      session.dockName ||
      (typeof targetPoller.lastData?.dockName === "string" &&
      targetPoller.lastData.dockName.trim()
        ? targetPoller.lastData.dockName.trim()
        : resolvedTargetDockId),
    primaryDisplay: resolvedPrimaryDisplay,
    minimumThreshold: resolvedMinimumThreshold,
    migrated: resolvedTargetDockId !== dockId,
  });
});

app.post("/live-activity/end", async (req, res) => {
  const { dockId, pushToken } = req.body;
  const normalizedPushToken = normalizeApnsDeviceToken(pushToken);

  if (!dockId || !normalizedPushToken) {
    return res
      .status(400)
      .json({ error: "Missing required fields: dockId, pushToken" });
  }

  logger.info(
    `Ending live activity: dock=${dockId}, token=${normalizedPushToken.substring(0, 8)}...`
  );

  const { endedCount, remainingCount } = await endTrackedSessionsForDock(
    dockId,
    (trackedPushToken) => trackedPushToken === normalizedPushToken,
    "user"
  );

  appendDiagnosticJsonLine("live_activity_session_end_requested", {
    dockId,
    pushToken: shortenIdentifier(normalizedPushToken),
    reason: "user",
    endedCount,
    remainingCount,
  });

  res.json({ success: true, dockId, message: "Live activity ended" });
});

app.post("/live-activity/arrive", async (req, res) => {
  const dockId =
    typeof req.body?.dockId === "string" ? req.body.dockId.trim() : "";
  const bodyDeviceToken = normalizeApnsDeviceToken(req.body?.deviceToken);
  const headerDeviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  const deviceToken = bodyDeviceToken || headerDeviceToken;
  const requestedBuildType =
    req.body?.buildType === undefined ? null : req.body.buildType;

  if (!dockId) {
    return res.status(400).json({ error: "Missing required field: dockId" });
  }

  if (!deviceToken) {
    return res.status(400).json({
      error: "Missing or invalid deviceToken (body.deviceToken or X-Device-Token)",
    });
  }

  if (
    requestedBuildType !== null &&
    requestedBuildType !== "development" &&
    requestedBuildType !== "production"
  ) {
    return res
      .status(400)
      .json({ error: 'buildType must be "development" or "production"' });
  }

  logger.info(
    `Ending live activity on arrival: dock=${dockId}, device=${deviceToken.substring(0, 8)}...`
  );

  const poller = dockPollers.get(dockId);
  const matchingSessions = [];
  const fallbackSessions = [];
  if (poller) {
    for (const [pushToken, session] of poller.tokens) {
      if (session.deviceToken !== deviceToken) continue;
      fallbackSessions.push([pushToken, session]);
      if (requestedBuildType && session.buildType !== requestedBuildType) continue;
      matchingSessions.push([pushToken, session]);
    }
  }

  const effectiveSessions =
    matchingSessions.length > 0 || !requestedBuildType ? matchingSessions : fallbackSessions;

  if (
    requestedBuildType &&
    matchingSessions.length === 0 &&
    fallbackSessions.length > 0
  ) {
    logger.warn(
      `Arrival request build type ${requestedBuildType} did not match tracked sessions for dock ${dockId}; falling back to ${fallbackSessions.length} device-matched session(s)`
    );
  }

  let confirmationSent = false;
  if (effectiveSessions.length > 0) {
    const [, session] = effectiveSessions[0];
    const dockName =
      session.dockName ||
      (typeof poller?.lastData?.dockName === "string" && poller.lastData.dockName.trim()
        ? poller.lastData.dockName.trim()
        : dockId);
    const confirmationBuildType = session.buildType;

    try {
      await sendArrivalConfirmationPush(deviceToken, confirmationBuildType, dockName);
      confirmationSent = true;
    } catch (err) {
      logger.error(
        `Failed to send arrival confirmation to ${deviceToken.substring(0, 8)}...:`,
        err.message
      );
    }
  }

  const matchedPushTokens = new Set(effectiveSessions.map(([pushToken]) => pushToken));
  let completedScheduledJourneyCount = 0;
  const completedScheduledJourneyIds = new Set();
  for (const [, session] of effectiveSessions) {
    const journeyId = session.scheduledJourneyId;
    if (!journeyId || completedScheduledJourneyIds.has(journeyId)) continue;
    try {
      if (await completeScheduledJourneyFromArrivalSession(session, dockId)) {
        completedScheduledJourneyCount += 1;
      }
      completedScheduledJourneyIds.add(journeyId);
    } catch (err) {
      logger.warn(
        `Failed to complete scheduled journey ${journeyId} after arrival at ${dockId}: ${err.message}`
      );
    }
  }

  const { endedCount, remainingCount } =
    matchedPushTokens.size > 0
      ? await endTrackedSessionsForDock(
          dockId,
          (pushToken) => matchedPushTokens.has(pushToken),
          "arrival"
        )
      : { endedCount: 0, remainingCount: poller?.tokens.size ?? 0 };

  appendDiagnosticJsonLine("live_activity_arrival_end_requested", {
    dockId,
    deviceToken: shortenIdentifier(deviceToken),
    requestedBuildType,
    matchingSessions: matchingSessions.length,
    fallbackSessions: fallbackSessions.length,
    effectiveSessions: effectiveSessions.length,
    endedCount,
    completedScheduledJourneyCount,
    confirmationSent,
    remainingCount,
  });

  res.json({
    success: true,
    dockId,
    endedCount,
    completedScheduledJourneyCount,
    confirmationSent,
    remainingCount,
    message:
      endedCount > 0
        ? "Live activity ended after dock arrival"
        : "No active live activity session matched this arrival update",
  });
});

app.post("/live-activity/start-arrival", (req, res) => {
  const startDockId =
    typeof req.body?.startDockId === "string" && req.body.startDockId.trim()
      ? req.body.startDockId.trim()
      : typeof req.body?.dockId === "string" && req.body.dockId.trim()
        ? req.body.dockId.trim()
        : "";
  const startDockName =
    typeof req.body?.startDockName === "string" && req.body.startDockName.trim()
      ? req.body.startDockName.trim()
      : startDockId;
  const endDock = sanitizeJourneyDock(req.body?.endDock);
  const bodyDeviceToken = normalizeApnsDeviceToken(req.body?.deviceToken);
  const headerDeviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  const deviceToken = bodyDeviceToken || headerDeviceToken;
  const requestedBuildType =
    req.body?.buildType === "development" || req.body?.buildType === "production"
      ? req.body.buildType
      : null;

  if (!startDockId) {
    return res.status(400).json({ error: "Missing required field: startDockId" });
  }

  if (!endDock) {
    return res.status(400).json({ error: "Valid endDock is required" });
  }

  if (!deviceToken) {
    return res.status(400).json({
      error: "Missing or invalid deviceToken (body.deviceToken or X-Device-Token)",
    });
  }

  if (req.body?.buildType !== undefined && !requestedBuildType) {
    return res
      .status(400)
      .json({ error: 'buildType must be "development" or "production"' });
  }

  const poller = dockPollers.get(startDockId);
  const matchingSessions = [];
  const fallbackSessions = [];
  if (poller) {
    for (const [, session] of poller.tokens) {
      if (session.deviceToken !== deviceToken) continue;
      fallbackSessions.push(session);
      if (requestedBuildType && session.buildType !== requestedBuildType) continue;
      matchingSessions.push(session);
    }
  }

  const effectiveSession =
    matchingSessions[0] || (!requestedBuildType ? fallbackSessions[0] : null) || null;
  const buildType =
    effectiveSession?.buildType || requestedBuildType || "development";
  const minimumSpaces = minimumThresholdForDisplay(
    effectiveSession?.minimumThresholds,
    "spaces"
  );
  const delayMs = Number.isFinite(START_ARRIVAL_DESTINATION_SPACE_ALERT_DELAY_MS)
    ? Math.max(0, START_ARRIVAL_DESTINATION_SPACE_ALERT_DELAY_MS)
    : 30000;

  scheduleStartArrivalDestinationSpaceAlert({
    deviceToken,
    buildType,
    startDockId,
    startDockName,
    endDock,
    minimumSpaces,
    delayMs,
    scheduledJourneyId:
      typeof req.body?.scheduledJourneyId === "string" ? req.body.scheduledJourneyId : null,
    adHocJourneyId:
      typeof req.body?.adHocJourneyId === "string" ? req.body.adHocJourneyId : null,
  });

  appendDiagnosticJsonLine("scheduled_start_arrival_destination_space_alert_scheduled", {
    startDockId,
    startDockName,
    endDockId: endDock.id,
    endDockName: endDock.name,
    deviceToken: shortenIdentifier(deviceToken),
    requestedBuildType,
    buildType,
    matchingSessions: matchingSessions.length,
    fallbackSessions: fallbackSessions.length,
    delayMs,
    minimumSpaces,
    scheduledJourneyId:
      typeof req.body?.scheduledJourneyId === "string" ? req.body.scheduledJourneyId : null,
    adHocJourneyId:
      typeof req.body?.adHocJourneyId === "string" ? req.body.adHocJourneyId : null,
  });

  res.json({
    success: true,
    startDockId,
    endDockId: endDock.id,
    delayMs,
    message: "Destination space availability notification scheduled",
  });
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

app.post("/app/background-location-event", (req, res) => {
  const body = req.body || {};
  const headerDeviceId =
    typeof req.headers["x-device-token"] === "string" ? req.headers["x-device-token"] : null;
  const bodyDeviceId =
    typeof body.deviceId === "string" ? body.deviceId.trim() : null;

  recordBackgroundLocationEvent({
    clientTimestamp: body.clientTimestamp,
    deviceId: bodyDeviceId || headerDeviceId || "unknown",
    event: body.event,
    appState: body.appState,
    backgroundRefreshStatus:
      typeof body.backgroundRefreshStatus === "string"
        ? body.backgroundRefreshStatus.trim()
        : null,
    dockId: typeof body.dockId === "string" ? body.dockId.trim() : null,
    dockName: typeof body.dockName === "string" ? body.dockName.trim() : null,
    distanceMeters: Number(body.distanceMeters),
    horizontalAccuracyMeters: Number(body.horizontalAccuracyMeters),
    arrivalThresholdMeters: Number(body.arrivalThresholdMeters),
    authorizationStatus:
      typeof body.authorizationStatus === "string" ? body.authorizationStatus.trim() : null,
    message: typeof body.message === "string" ? body.message.trim() : null,
    raw: body.raw && typeof body.raw === "object" ? body.raw : null,
  });

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
        scheduledJourneyId: session.scheduledJourneyId || null,
        scheduledJourneyPhase: session.scheduledJourneyPhase || null,
        adHocJourneyId: session.adHocJourneyId || null,
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
          scheduledJourneyId: latestSession.scheduledJourneyId,
          scheduledJourneyPhase: latestSession.scheduledJourneyPhase,
        }
      : null,
  });
});

app.post("/live-activity/device/end", async (req, res) => {
  const dockId =
    typeof req.body?.dockId === "string" ? req.body.dockId.trim() : "";
  const bodyDeviceToken = normalizeApnsDeviceToken(req.body?.deviceToken);
  const headerDeviceToken = normalizeApnsDeviceToken(req.headers["x-device-token"]);
  const deviceToken = bodyDeviceToken || headerDeviceToken;
  const requestedBuildType =
    req.body?.buildType === "development" || req.body?.buildType === "production"
      ? req.body.buildType
      : null;

  if (!dockId) {
    return res.status(400).json({ error: "Missing required field: dockId" });
  }

  if (!deviceToken) {
    return res
      .status(400)
      .json({ error: "Missing or invalid deviceToken (body.deviceToken or X-Device-Token)" });
  }

  logger.info(
    `Ending live activity from device action: dock=${dockId}, device=${deviceToken.substring(0, 8)}...`
  );

  const { endedCount, remainingCount } = await endTrackedSessionsForDock(
    dockId,
    (_pushToken, session) =>
      session.deviceToken === deviceToken &&
      (!requestedBuildType || session.buildType === requestedBuildType),
    "notification_action"
  );

  res.json({
    success: true,
    dockId,
    endedCount,
    remainingCount,
    message:
      endedCount > 0
        ? "Live activity ended for this device"
        : "No active live activity session matched this device action",
  });
});

// ── Complication Refresh Endpoints ────────────────────────────────────

// Register a device token to receive periodic silent background pushes.
// The iOS app calls this on launch whenever it receives a fresh APNs device token.
app.post("/complication/register", (req, res) => {
  const { deviceToken, buildType } = req.body;
  const normalizedDeviceToken = normalizeApnsDeviceToken(deviceToken);

  if (!normalizedDeviceToken || !buildType) {
    return res.status(400).json({ error: "Missing required fields: deviceToken, buildType" });
  }
  if (buildType !== "development" && buildType !== "production") {
    return res.status(400).json({ error: 'buildType must be "development" or "production"' });
  }

  const isNew = !complicationTokens.has(normalizedDeviceToken);
  complicationTokens.set(normalizedDeviceToken, { buildType, registeredAt: Date.now() });
  saveComplicationTokens();

  logger.info(
    `Complication token ${isNew ? "registered" : "refreshed"}: ` +
    `${normalizedDeviceToken.substring(0, 8)}... (${buildType}, total: ${complicationTokens.size})`
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
  const normalizedDeviceToken = normalizeApnsDeviceToken(deviceToken);

  if (!normalizedDeviceToken) {
    return res.status(400).json({ error: "Missing required field: deviceToken" });
  }

  const existed = complicationTokens.delete(normalizedDeviceToken);
  saveComplicationTokens();
  logger.info(
    `Complication token unregistered: ${normalizedDeviceToken.substring(0, 8)}... ` +
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

async function processScheduledJourneyStarts() {
  if (!scheduledJourneysCollection) return;

  const activeJourneys = await scheduledJourneysCollection
    .find({
      deletedAt: { $exists: false },
      "activeRun.phase": { $in: ["start", "end"] },
    })
    .toArray();

  for (const journey of activeJourneys) {
    if (!shouldEndScheduledJourneyWindow(journey)) continue;
    for (const dockId of [journey.startDock.id, journey.endDock.id]) {
      await endTrackedSessionsForDock(
        dockId,
        (_pushToken, session) =>
          session.scheduledJourneyId === journey._id.toString() ||
          session.deviceToken === journey.deviceToken,
        "scheduled_window_end"
      );
    }
    await scheduledJourneysCollection.updateOne(
      { _id: journey._id },
      { $set: { activeRun: null, updatedAt: new Date() } }
    );
    logger.info(`Ended scheduled journey ${journey._id} at end of window`);
  }

  const candidates = await scheduledJourneysCollection
    .find({
      enabled: { $ne: false },
      deletedAt: { $exists: false },
    })
    .toArray();

  for (const journey of candidates) {
    const decision = scheduledJourneyStartDecision(journey);
    if (!decision.canStart) {
      if (decision.reason !== "time_mismatch" && decision.reason !== "weekday_mismatch") {
        appendScheduledJourneyCheckDiagnostic(
          "scheduled_journey_start_skipped",
          journey,
          decision
        );
      }
      continue;
    }

    const runKey = decision.runKey || scheduledRunKey(journey);
    appendScheduledJourneyCheckDiagnostic(
      "scheduled_journey_start_eligible",
      journey,
      decision
    );
    if (!normalizeApnsDeviceToken(journey.pushToStartToken)) {
      appendScheduledJourneyCheckDiagnostic(
        "scheduled_journey_start_missing_push_to_start_token",
        journey,
        decision
      );
      logger.warn(
        `Scheduled journey ${journey._id} was eligible for ${runKey} but has no push-to-start token`
      );
      continue;
    }

    try {
      const arbitration = await prepareScheduledJourneyStart(journey, "schedule");
      if (!arbitration.canStart) {
        continue;
      }
      await sendScheduledJourneyStartPush(journey, "schedule");
      appendScheduledJourneyCheckDiagnostic(
        "scheduled_journey_start_push_sent",
        journey,
        decision,
        { source: "schedule" }
      );
      try {
        await sendScheduledJourneyInitialAvailabilityPush(journey);
      } catch (err) {
        logger.warn(
          `Failed to send initial scheduled journey availability notification for ${journey._id}: ${err.message}`
        );
      }
      await scheduledJourneysCollection.updateOne(
        { _id: journey._id },
        {
          $set: {
            activeRun: {
              phase: "start",
              dockId: journey.startDock.id,
              dockName: journey.startDock.name,
              startedAt: new Date(),
              runKey,
            },
            updatedAt: new Date(),
          },
        }
      );
      appendScheduledJourneyCheckDiagnostic(
        "scheduled_journey_active_run_marked",
        journey,
        decision,
        { activeDockId: journey.startDock.id, activeDockName: journey.startDock.name }
      );
      logger.info(`Started scheduled journey ${journey._id} for ${journey.deviceId}`);
    } catch (err) {
      logger.error(`Failed to start scheduled journey ${journey._id}: ${err.message}`);
      appendScheduledJourneyCheckDiagnostic(
        "scheduled_journey_start_failed",
        journey,
        decision,
        { error: err.message }
      );
      if (isApnsTokenInvalidError(err)) {
        await scheduledJourneysCollection.updateOne(
          { _id: journey._id },
          { $unset: { pushToStartToken: "" }, $set: { updatedAt: new Date() } }
        );
      }
    }
  }
}

app.listen(PORT, () => {
  logger.info(`My Boris Bikes Live Activity server running on port ${PORT}`);
  logger.info(`Poll interval: ${POLL_INTERVAL_MS}ms`);
  logger.info(`Session timeout: ${SESSION_TIMEOUT_MS / 1000 / 60 / 60} hours`);
  logger.info(
    `Max notification window: ${EFFECTIVE_MAX_NOTIFICATION_WINDOW_MS / 1000 / 60 / 60} hours`
  );
  logger.info(`APNS live activity topic: ${APNS_TOPIC}`);
  logger.info(`APNS app/background topic: ${APNS_BACKGROUND_TOPIC}`);

  // Start periodic TfL data freshness monitoring (independent of live activity polling)
  checkTflDataFreshness().catch(() => {});
  setInterval(checkTflDataFreshness, TFL_FRESHNESS_CHECK_INTERVAL_MS);

  connectMongoIfConfigured().then(() => {
    processScheduledJourneyStarts().catch((err) => {
      logger.error(`Scheduled journey check failed: ${err.message}`);
    });
    setInterval(() => {
      processScheduledJourneyStarts().catch((err) => {
        logger.error(`Scheduled journey check failed: ${err.message}`);
      });
    }, SCHEDULED_JOURNEY_CHECK_INTERVAL_MS);
  });
});
