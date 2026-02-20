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
const APNS_KEY_ID = process.env.APNS_KEY_ID || "UQ2DV6UTF4";
const APNS_TEAM_ID = process.env.APNS_TEAM_ID || "SJ8X4DLAN9";
const APNS_KEY_PATH =
  process.env.APNS_KEY_PATH ||
  path.join(__dirname, "certs", "APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8");
const APNS_TOPIC =
  process.env.APNS_TOPIC ||
  "dev.skynolimit.myborisbikes.My-Boris-Bikes.push-type.liveactivity";
const TFL_API_BASE = "https://api.tfl.gov.uk";
const LOG_DIR = process.env.LOG_DIR || path.join(__dirname, "logs");
const MAX_LIVE_ACTIVITY_ALTERNATIVES = 5;

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
  labelNames: ["event", "build_type", "status"], // event: "update"/"end", status: "success"/"failure"
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
// dockPollers: Map<dockId, { interval, lastData, tokens: Map<pushToken, { buildType, startedAt, alternatives }> }>
const dockPollers = new Map();

// ── TfL API ──────────────────────────────────────────────────────────
async function fetchDockData(dockId) {
  const timestamp = Date.now();
  const urlPath = `/Place/${dockId}`;
  const url = `${TFL_API_BASE}${urlPath}?cb=${timestamp}`;
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
    dockPollsTotal.inc({ dock_id: dockId, status: "failure" });
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
    dockPollsTotal.inc({ dock_id: dockId, status: "failure" });
    throw new Error(`TfL API returned ${res.status} for ${dockId}`);
  }

  try {
    const data = await res.json();
    dockPollsTotal.inc({ dock_id: dockId, status: "success" });
    return parseBikePointData(data);
  } catch (err) {
    dockPollsTotal.inc({ dock_id: dockId, status: "failure" });
    throw err;
  }
}

function parseBikePointData(data) {
  const props = data.additionalProperties || [];
  const getProp = (key) => {
    const prop = props.find((p) => p.key === key);
    return prop ? parseInt(prop.value, 10) || 0 : 0;
  };
  return {
    standardBikes: getProp("NbStandardBikes"),
    eBikes: getProp("NbEBikes"),
    emptySpaces: getProp("NbEmptyDocks"),
  };
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
    ...data,
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
  for (const [pushToken, session] of poller.tokens) {
    const timeoutMs = session.expiryMs || SESSION_TIMEOUT_MS;
    const elapsedMs = now - session.startedAt;
    const remainingMs = timeoutMs - elapsedMs;

    // Debug log every poll to track time to expiry
    if (timeoutMs <= 120000) { // Only log for sessions with short expiry (<=2 minutes)
      logger.info(
        `Dock ${dockId}: ${Math.floor(remainingMs / 1000)}s remaining until expiry (${elapsedMs / 1000}s elapsed of ${timeoutMs / 1000}s)`
      );
    }

    if (elapsedMs >= timeoutMs) {
      logger.info(
        `Session expired for dock ${dockId}, token ${pushToken.substring(0, 8)}... (after ${timeoutMs / 1000}s)`
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
    }
  }

  // If no tokens left after expiry check, stop polling
  if (poller.tokens.size === 0) {
    stopPollingForDock(dockId);
    return;
  }

  try {
    const data = await fetchDockData(dockId);
    const hasChanged =
      !poller.lastData ||
      poller.lastData.standardBikes !== data.standardBikes ||
      poller.lastData.eBikes !== data.eBikes ||
      poller.lastData.emptySpaces !== data.emptySpaces;

    if (hasChanged) {
      logger.info(
        `Dock ${dockId} changed: bikes=${data.standardBikes}, eBikes=${data.eBikes}, spaces=${data.emptySpaces}`
      );
      poller.lastData = data;

      // Send update to all registered tokens for this dock
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
      await Promise.all(pushPromises);
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

app.post("/live-activity/start", (req, res) => {
  const { dockId, pushToken, buildType, expirySeconds, alternatives } = req.body;

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

  // Use client-provided expiry or fall back to default session timeout
  const expiryMs = expirySeconds
    ? expirySeconds * 1000
    : SESSION_TIMEOUT_MS;
  const normalizedAlternatives = sanitizeAlternatives(alternatives);

  logger.info(
    `Starting live activity: dock=${dockId}, build=${buildType}, expires in ${expiryMs / 1000}s`
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
    startedAt: Date.now(),
    expiryMs,
    alternatives: normalizedAlternatives,
  });

  // Start polling if not already
  startPollingForDock(dockId);

  // Update metrics
  liveActivitiesTotal.inc({ build_type: buildType });
  liveActivitiesActive.set(
    Array.from(dockPollers.values()).reduce(
      (sum, poller) => sum + poller.tokens.size,
      0
    )
  );

  res.json({
    success: true,
    dockId,
    message: "Live activity started",
    expiresIn: `${expiryMs / 1000} seconds`,
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
  liveActivitiesActive.set(
    Array.from(dockPollers.values()).reduce(
      (sum, poller) => sum + poller.tokens.size,
      0
    )
  );

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
      apnsEnvironment: {
        keyId: APNS_KEY_ID,
        teamId: APNS_TEAM_ID,
        topic: APNS_TOPIC,
      },
    },
    activity: {
      activeDockPollers: dockPollers.size,
      totalTrackedTokens: Array.from(dockPollers.values()).reduce(
        (sum, poller) => sum + poller.tokens.size,
        0
      ),
      activeTestSessions: testSessions.size,
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
        alternativesCount: Array.isArray(session.alternatives)
          ? session.alternatives.length
          : 0,
        startedAt: new Date(session.startedAt).toISOString(),
        expiresAt: new Date(
          session.startedAt + (session.expiryMs || SESSION_TIMEOUT_MS)
        ).toISOString(),
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

app.listen(PORT, () => {
  logger.info(`My Boris Bikes Live Activity server running on port ${PORT}`);
  logger.info(`Poll interval: ${POLL_INTERVAL_MS}ms`);
  logger.info(`Session timeout: ${SESSION_TIMEOUT_MS / 1000 / 60 / 60} hours`);
});
