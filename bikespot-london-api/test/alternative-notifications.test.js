const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { buildAlternativeNotification } = require("../alternative-notifications");

const docks = [
  { id: "main", dockName: "Allington Street", latitude: 51.5, longitude: 0 },
  { id: "station", dockName: "Warwick Row", latitude: 51.501, longitude: 0, standardBikes: 12, eBikes: 1, emptySpaces: 0 },
  { id: "ashley", dockName: "Ashley Place, Victoria", latitude: 51.502, longitude: 0, standardBikes: 5, eBikes: 2, emptySpaces: 1 },
  { id: "howick", dockName: "Howick Place", latitude: 51.503, longitude: 0, standardBikes: 3, eBikes: 3, emptySpaces: 8 },
  { id: "fourth", dockName: "Fourth", latitude: 51.504, longitude: 0, standardBikes: 20, eBikes: 4, emptySpaces: 10 },
].map((dock) => ({ isAvailable: true, ...dock }));
const docksById = new Map(docks.map((dock) => [dock.id, dock]));
const preferences = {
  alternatives: { main: ["station", "ashley", "howick", "fourth"] },
  aliases: { station: "Station" },
  settings: { minBikes: 5, minEBikes: 2, minSpaces: 5, maxCount: 1, useMinimumThresholds: true },
};
const options = { dockId: "main", primaryDisplay: "bikes", preferences, docksById };

test("top three custom docks keep order, aliases and below-threshold counts", () => {
  assert.equal(buildAlternativeNotification(options),
    "Alternatives: Station - 12 bikes; Ashley Place, Victoria - 5 bikes; Howick Place - 3 bikes");
  assert.equal(buildAlternativeNotification({ ...options, primaryDisplay: "spaces" }),
    "Alternatives: Station - 0 spaces; Ashley Place, Victoria - 1 space; Howick Place - 8 spaces");
});

test("bike filter controls the alternative counts and labels", () => {
  assert.match(buildAlternativeNotification({ ...options, primaryDisplay: "eBikes" }), /Station - 1 e-bike;/);
  assert.match(buildAlternativeNotification({ ...options, primaryDisplay: "allBikes" }), /Station - 13 bikes;/);
});

test("automatic docks are nearest usable docks with availability", () => {
  const result = buildAlternativeNotification({ ...options, preferences: null, primaryDisplay: "spaces" });
  assert.equal(result, "Alternatives: Ashley Place, Victoria - 1 space; Howick Place - 8 spaces; Fourth - 10 spaces");
});

test("explicitly empty custom list never falls back to automatic docks", () => {
  assert.equal(buildAlternativeNotification({ ...options, preferences: { ...preferences, alternatives: { main: [] } } }), null);
});

test("missing, closed, duplicate and primary docks are omitted", () => {
  const custom = { ...preferences, alternatives: { main: ["main", "missing", "station", "station", "ashley", "howick"] } };
  const catalogue = new Map(docksById);
  catalogue.set("ashley", { ...catalogue.get("ashley"), isAvailable: false });
  assert.equal(buildAlternativeNotification({ ...options, preferences: custom, docksById: catalogue }),
    "Alternatives: Station - 12 bikes; Howick Place - 3 bikes");
  assert.equal(buildAlternativeNotification({ ...options, docksById: new Map() }), null);
});

// Exercise the actual server send functions without starting its HTTP server,
// MongoDB connection, timers, or APNs transport.
const source = fs.readFileSync(require.resolve("../server"), "utf8");
function serverHarness(overrides = {}) {
  const pushes = [];
  const context = vm.createContext({
    buildAlternativeNotification,
    loadDeviceDockPreferences: async () => preferences,
    loadAlternativeDockSnapshots: async () => docksById,
    fetchDockData: async () => ({ standardBikes: 2, eBikes: 0, emptySpaces: 2 }),
    normalizeApnsDeviceToken: (token) => token,
    LIVE_ACTIVITY_ALERT_CATEGORY: "availability",
    VALID_PRIMARY_DISPLAYS: new Set(["bikes", "eBikes", "allBikes", "spaces"]),
    scheduledStartArrivalDestinationAlerts: new Map(),
    appendDiagnosticJsonLine() {},
    shortenIdentifier: (value) => value,
    sendAlertPush: async (...args) => { pushes.push(args); return { buildType: "production" }; },
    logger: { warn() {}, error(...args) { assert.fail(args.join(" ")); } },
    ...overrides,
  });
  for (const name of ["sanitizeThresholdValue", "sanitizePrimaryDisplay", "sanitizeBikeDataFilter", "sanitizeDockName",
    "singularMetricLabel", "pluralMetricLabel", "metricLabelForValue", "buildAvailabilitySnapshotMessage",
    "primaryValueForDisplay", "minimumThresholdForDisplay", "scheduledJourneyStartAlertBody",
    "scheduledJourneyDestinationAvailabilityBody", "sendAlternativeAvailabilityPush", "sendAvailabilityAlertPush",
    "sendScheduledJourneyInitialAvailabilityPush", "sendScheduledJourneyDestinationAvailabilityPushForSession",
    "startArrivalDestinationAlertKey", "scheduleStartArrivalDestinationSpaceAlert"]) {
    const match = source.match(new RegExp(`(?:async )?function ${name}\\([^]*?\\n\\}(?=\\n|$)`));
    assert.ok(match, name);
    vm.runInContext(match[0], context);
  }
  return { context, pushes };
}
const session = { deviceToken: "token", buildType: "development", primaryDisplay: "bikes", minimumThresholds: { bikes: 5, spaces: 5 } };

test("journey and standalone warnings each send an ordered follow-up using the resolved APNs environment", async () => {
  for (const scheduledJourneyPhase of [undefined, "start", "end"]) {
    const { context, pushes } = serverHarness();
    const display = scheduledJourneyPhase === "end" ? "spaces" : "bikes";
    for (const count of [3, 2, 1, 0]) {
      await context.sendAvailabilityAlertPush("token", "development", "Warning", "main", "Allington Street",
        { ...session, scheduledJourneyPhase, primaryDisplay: display },
        { standardBikes: count, emptySpaces: count });
    }
    assert.equal(pushes.length, 8);
    for (let index = 0; index < pushes.length; index += 2) {
      assert.equal(pushes[index][4], "availability_alert");
      assert.equal(pushes[index + 1][4], "availability_alternatives");
      assert.equal(pushes[index + 1][1], "production");
      assert.match(pushes[index + 1][3], display === "spaces" ? /0 spaces/ : /12 bikes/);
    }
  }
});

test("no follow-up at or above threshold, or with warnings disabled", async () => {
  const { context, pushes } = serverHarness({ loadAlternativeDockSnapshots: async () => { assert.fail("unnecessary fetch"); } });
  for (const [count, threshold] of [[5, 5], [6, 5], [0, 0]]) {
    await context.sendAlternativeAvailabilityPush({ ...session, minimumThresholds: { bikes: threshold } },
      "main", "Allington Street", { standardBikes: count });
  }
  assert.equal(pushes.length, 0);
});

test("scheduled start and destination snapshots also send alternatives", async () => {
  const { context, pushes } = serverHarness();
  await context.sendScheduledJourneyInitialAvailabilityPush({ deviceToken: "token", deviceId: "device", bikeDataFilter: "bikesOnly", startDock: { id: "main", name: "Allington Street" } });
  await context.sendScheduledJourneyDestinationAvailabilityPushForSession(session, "main", "Allington Street", { emptySpaces: 2 });
  assert.deepEqual(pushes.map((push) => push[4]), ["scheduled_journey_initial_availability", "availability_alternatives", "scheduled_journey_destination_availability", "availability_alternatives"]);
});

test("delayed destination snapshot uses the end dock's saved list and spaces", async () => {
  let callback;
  const { context, pushes } = serverHarness({ setTimeout: (action) => { callback = action; return 1; } });
  context.scheduleStartArrivalDestinationSpaceAlert({ deviceToken: "token", buildType: "production",
    startDockId: "other", endDock: { id: "main", name: "Allington Street" }, minimumSpaces: 5,
    deviceId: "device", dockPreferences: preferences, delayMs: 30000 });
  await callback();
  assert.deepEqual(pushes.map((push) => push[4]), ["availability_alert", "availability_alternatives"]);
  assert.match(pushes[1][3], /Station - 0 spaces/);
});

test("empty alternatives do not send an empty follow-up", async () => {
  const { context, pushes } = serverHarness({ loadAlternativeDockSnapshots: async () => new Map() });
  await context.sendAvailabilityAlertPush("token", "development", "Warning", "main", "Allington Street", session, { standardBikes: 2 });
  assert.equal(pushes.length, 1);
});

test("catalogue and follow-up failures preserve a successful primary alert", async () => {
  for (const overrides of [
    { loadAlternativeDockSnapshots: async () => { throw new Error("TfL unavailable"); } },
    { sendAlertPush: async (...args) => { if (args[4] === "availability_alternatives") throw new Error("APNs unavailable"); return { buildType: "production" }; } },
  ]) {
    const { context } = serverHarness(overrides);
    const result = await context.sendAvailabilityAlertPush("token", "development", "Warning", "main", "Allington Street", session, { standardBikes: 2 });
    assert.equal(result.buildType, "production");
  }
});

test("failed primary alert never sends an orphan alternatives notification", async () => {
  let sends = 0;
  const { context } = serverHarness({ sendAlertPush: async () => { sends++; throw new Error("APNs unavailable"); } });
  await assert.rejects(context.sendAvailabilityAlertPush("token", "development", "Warning", "main", "Allington Street", session, { standardBikes: 2 }));
  assert.equal(sends, 1);
});
