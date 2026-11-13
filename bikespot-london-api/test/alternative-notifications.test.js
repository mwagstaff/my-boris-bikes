const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { buildAlternativeNotification } = require("../alternative-notifications");
const { createDockSnapshotLoader } = require("../dock-preferences");

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
    "Alternatives: Station has 12 bikes; Ashley Place, Victoria has 5 bikes; Howick Place has 3 bikes.");
  assert.equal(buildAlternativeNotification({ ...options, primaryDisplay: "spaces" }),
    "Alternatives: Station has 0 spaces; Ashley Place, Victoria has 1 space; Howick Place has 8 spaces.");
});

test("bike filter controls the alternative counts and labels", () => {
  assert.match(buildAlternativeNotification({ ...options, primaryDisplay: "eBikes" }), /Station has 1 e-bike;/);
  assert.match(buildAlternativeNotification({ ...options, primaryDisplay: "allBikes" }), /Station has 13 bikes;/);
});

test("automatic docks are nearest usable docks with availability", () => {
  const result = buildAlternativeNotification({ ...options, preferences: null, primaryDisplay: "spaces" });
  assert.equal(result, "Alternatives: Ashley Place, Victoria has 1 space; Howick Place has 8 spaces; Fourth has 10 spaces.");
});

test("short custom lists are filled with nearest available docks without duplicates", () => {
  const custom = { ...preferences, alternatives: { main: ["howick"] } };
  assert.equal(buildAlternativeNotification({ ...options, primaryDisplay: "spaces", preferences: custom }),
    "Alternatives: Howick Place has 8 spaces; Ashley Place, Victoria has 1 space; Fourth has 10 spaces.");
});

test("empty custom lists fall back to nearest available docks", () => {
  assert.equal(buildAlternativeNotification({ ...options, primaryDisplay: "spaces", preferences: { ...preferences, alternatives: { main: [] } } }),
    "Alternatives: Ashley Place, Victoria has 1 space; Howick Place has 8 spaces; Fourth has 10 spaces.");
});

test("missing, closed, duplicate and primary docks are omitted", () => {
  const custom = { ...preferences, alternatives: { main: ["main", "missing", "station", "station", "ashley", "howick"] } };
  const catalogue = new Map(docksById);
  catalogue.set("ashley", { ...catalogue.get("ashley"), isAvailable: false });
  assert.equal(buildAlternativeNotification({ ...options, preferences: custom, docksById: catalogue }),
    "Alternatives: Station has 12 bikes; Howick Place has 3 bikes; Fourth has 20 bikes.");
  assert.equal(buildAlternativeNotification({ ...options, docksById: new Map() }), null);
});

test("saved docks remain usable when the primary dock has no location", () => {
  const catalogue = new Map(docksById);
  catalogue.delete("main");
  assert.equal(buildAlternativeNotification({ ...options, docksById: catalogue }),
    "Alternatives: Station has 12 bikes; Ashley Place, Victoria has 5 bikes; Howick Place has 3 bikes.");
});

// Exercise real server producers without HTTP, database, timers or APNs.
const source = fs.readFileSync(require.resolve("../server"), "utf8");
function serverHarness(overrides = {}) {
  const pushes = [];
  const context = vm.createContext({
    ...require("../notification-content"),
    buildAlternativeNotification,
    notificationDockName: require("../notification-dock-name").notificationDockName,
    loadDeviceDockPreferences: async () => preferences,
    loadAlternativeDockSnapshots: async () => docksById,
    fetchDockData: async () => ({ standardBikes: 2, eBikes: 0, emptySpaces: 2 }),
    fetchNotificationDockData: async () => ({ standardBikes: 2, eBikes: 0, emptySpaces: 2 }),
    fetchVerifiedDestinationAvailability: require("../destination-availability").fetchVerifiedDestinationAvailability,
    normalizeApnsDeviceToken: token => token,
    LIVE_ACTIVITY_ALERT_CATEGORY: "availability",
    VALID_PRIMARY_DISPLAYS: new Set(["bikes", "eBikes", "allBikes", "spaces"]),
    scheduledStartArrivalDestinationAlerts: new Map(),
    appendDiagnosticJsonLine() {}, shortenIdentifier: value => value,
    sendAlertPush: async (...args) => { pushes.push(args); return { buildType: "production" }; },
    logger: { warn() {}, error(...args) { assert.fail(args.join(" ")); } },
    crypto: require("node:crypto"), dockPollers: new Map(),
    ...overrides,
  });
  for (const name of ["sanitizeThresholdValue", "sanitizePrimaryDisplay", "sanitizeBikeDataFilter", "sanitizeDockName",
    "buildAvailabilityAlertMessage",
    "primaryValueForDisplay", "minimumThresholdForDisplay", "alternativeAvailabilityText", "sendAvailabilityAlertPush",
    "composeDestinationNotification", "sendScheduledJourneyDestinationAvailabilityPushForSession", "sendHalfwayNotificationIfNeeded",
    "startArrivalDestinationAlertKey", "scheduleStartArrivalDestinationSpaceAlert", "sendArrivalConfirmationPush", "sendScheduledJourneyStartPush"]) {
    const match = source.match(new RegExp(`(?:async )?function ${name}\\([^]*?\\n\\}(?=\\n|$)`));
    assert.ok(match, name);
    vm.runInContext(match[0], context);
  }
  return { context, pushes };
}
const session = { deviceToken: "token", buildType: "development", primaryDisplay: "bikes", minimumThresholds: { bikes: 5, spaces: 5 } };

test("journey and standalone warnings send exactly one alert containing alternatives", async () => {
  for (const scheduledJourneyPhase of [undefined, "start", "end"]) {
    const { context, pushes } = serverHarness();
    const display = scheduledJourneyPhase === "end" ? "spaces" : "bikes";
    for (const count of [3, 2, 1, 0]) {
      await context.sendAvailabilityAlertPush("token", "development", "Warning.", "main", "Allington Street",
        { ...session, scheduledJourneyPhase, primaryDisplay: display }, { standardBikes: count, emptySpaces: count });
    }
    assert.equal(pushes.length, 4);
    for (const push of pushes) {
      assert.equal(push[4], "availability_alert");
      assert.match(push[3], /Warning\. Alternatives:/);
      assert.match(push[3], display === "spaces" ? /0 spaces/ : /12 bikes/);
      assert.equal(push[6].category, "availability");
    }
  }
});

test("no alternatives at or above threshold, or with warnings disabled", async () => {
  const { context } = serverHarness({ loadAlternativeDockSnapshots: async () => { assert.fail("unnecessary fetch"); } });
  for (const [count, threshold] of [[5, 5], [6, 5], [0, 0]]) {
    assert.equal(await context.alternativeAvailabilityText({ ...session, minimumThresholds: { bikes: threshold } },
      "main", { standardBikes: count }), "");
  }
});

test("transition, halfway and approach use aliases and one body with alternatives", async () => {
  const { context } = serverHarness();
  const state = { ...session, dockPreferences: { ...preferences, aliases: { ...preferences.aliases, main: "Office" } } };
  for (const [kind, title, prefix] of [
    ["transition", "Journey to Office", "You’ve reached Home. Office has 2 spaces available."],
    ["halfway", "Halfway to Office", "You’re halfway to Office, which has 2 spaces available."],
    ["approach", "Approaching Office", "Office has 2 spaces available."],
  ]) {
    const message = await context.composeDestinationNotification(state, "main", "Allington Street", { emptySpaces: 2 }, kind, "Home");
    assert.equal(message.title, title);
    assert.ok(message.body.startsWith(prefix));
    assert.match(message.body, /Alternatives: Station has 0 spaces;/);
    assert.doesNotMatch(message.body, /Now watching|meeting your minimum/);
  }
});

test("unavailable destination data does not invent a zero count or alternatives", async () => {
  const { context } = serverHarness({ loadAlternativeDockSnapshots: async () => assert.fail("must not fetch") });
  const message = await context.composeDestinationNotification(session, "main", "Office", null, "halfway");
  assert.equal(message.body, "You’re halfway to Office. Space availability at Office is currently unavailable.");
  assert.doesNotMatch(message.title, /Full/);
});

test("alternative lookup failures preserve the single primary alert", async () => {
  for (const loadAlternativeDockSnapshots of [async () => new Map(), async () => { throw new Error("offline"); }]) {
    const { context, pushes } = serverHarness({ loadAlternativeDockSnapshots });
    await context.sendAvailabilityAlertPush("token", "development", "Warning.", "main", "Allington Street", session, { standardBikes: 2 });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0][3], "Warning.");
  }
});

test("failed primary alert never sends orphan alternatives", async () => {
  let sends = 0;
  const { context } = serverHarness({ sendAlertPush: async () => { sends++; throw new Error("APNs unavailable"); } });
  await assert.rejects(context.sendAvailabilityAlertPush("token", "development", "Warning", "main", "Allington Street", session, { standardBikes: 2 }));
  assert.equal(sends, 1);
});

test("destination approach reloads edited aliases and emits one appropriately titled alert", async () => {
  let callback;
  const latest = { ...preferences, aliases: { main: "New office", station: "New station" } };
  const { context, pushes } = serverHarness({ setTimeout: action => { callback = action; return 1; },
    loadDeviceDockPreferences: async () => latest });
  context.scheduleStartArrivalDestinationSpaceAlert({ deviceToken: "token", buildType: "production",
    startDockId: "other", endDock: { id: "main", name: "Allington Street" }, minimumSpaces: 5,
    deviceId: "device", dockPreferences: { ...preferences, aliases: { main: "Old office" } }, delayMs: 0,
    triggerSource: "destination_approach" });
  await callback();
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0][2], "Approaching New office");
  assert.match(pushes[0][3], /New office has 2 spaces available\. Alternatives: New station/);
});

test("arrival wording does not claim a bike was docked or monitoring stopped", async () => {
  const { context, pushes } = serverHarness();
  await context.sendArrivalConfirmationPush("token", "production", "Office");
  assert.equal(pushes[0][2], "Arrived at Office");
  assert.equal(pushes[0][3], "You’ve reached Office.");
});

test("availability changes preserve zero, low and recovery triggers with approved wording", () => {
  const { context } = serverHarness();
  assert.equal(context.buildAvailabilityAlertMessage("Office", "spaces", 6, 2, 5), "Office has 2 spaces available, below your minimum of 5.");
  assert.equal(context.buildAvailabilityAlertMessage("Office", "spaces", 2, 6, 5), "Office now has 6 spaces available.");
  assert.equal(context.buildAvailabilityAlertMessage("Home", "bikes", 1, 0, 0), "Home has no bikes available.");
  assert.equal(context.buildAvailabilityAlertMessage("Home", "bikes", 0, 1, 0), "Home now has 1 bike available.");
  assert.equal(context.buildAvailabilityAlertMessage("Home", "bikes", 7, 8, 5), null);
  assert.equal(context.buildAvailabilityAlertMessage("Home", "bikes", 2, 2, 5), null);
});

test("scheduled startup embeds counts and alternatives into the sole Live Activity start alert", async () => {
  for (const bikeDataFilter of ["bikesOnly", "eBikesOnly", "both"]) {
    const payloads = [];
    const { context, pushes } = serverHarness({
      refreshSessionDockPreferences: async () => {}, LIVE_ACTIVITY_STALE_AFTER_SECONDS: 120,
      APNS_TOPIC: "test.push-type.liveactivity", recordPushEvent() {}, apnsPushesTotal: { inc() {} },
      sendApnsRequestWithFallback: async (_token, _build, payload) => { payloads.push(JSON.parse(payload)); return { statusCode: 200, buildType: "production" }; },
    });
    await context.sendScheduledJourneyStartPush({ _id: "journey", deviceId: "device", pushToStartToken: "start-token",
      startDock: { id: "main", name: "Home" }, endDock: { id: "end", name: "Office" }, bikeDataFilter });
    assert.equal(payloads.length, 1);
    assert.equal(pushes.length, 0);
    assert.match(payloads[0].aps.alert.body, /Home has .* available\. Alternatives:/);
    assert.doesNotMatch(payloads[0].aps.alert.body, /Now watching|meeting your minimum/);
  }
});

test("halfway triggers once after crossing 50 and survives re-registration and restart", async () => {
  const os = require("node:os");
  const path = require("node:path");
  const { JourneyNotificationReceipts } = require("../journey-notification-receipts");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "bikespot-halfway-"));
  try {
    const file = path.join(directory, "receipts.json");
    const state = { ...session, adHocJourneyId: "ride", deviceId: "device", scheduledJourneyPhase: "end",
      rideStartedAtEpochSeconds: Date.now() / 1000 - 300,
      journeyProgress: { percent: 49, updatedAtEpochSeconds: Date.now() / 1000 } };
    const dockPollers = new Map([["main", { tokens: new Map([["token", state]]) }]]);
    const { context, pushes } = serverHarness({ dockPollers, journeyNotificationReceipts: new JourneyNotificationReceipts(file) });
    await context.sendHalfwayNotificationIfNeeded(state, "main");
    assert.equal(pushes.length, 0);
    state.journeyProgress.percent = 51;
    await Promise.all([context.sendHalfwayNotificationIfNeeded(state, "main"), context.sendHalfwayNotificationIfNeeded(state, "main")]);
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0][4], "journey_halfway");
    state.journeyProgress.percent = 45;
    await context.sendHalfwayNotificationIfNeeded(state, "main");
    state.journeyProgress.percent = 65;
    context.journeyNotificationReceipts = new JourneyNotificationReceipts(file);
    const restored = { ...state };
    dockPollers.get("main").tokens = new Map([["new-token", restored]]);
    await context.sendHalfwayNotificationIfNeeded(restored, "main");
    assert.equal(pushes.length, 1);
    restored.rideStartedAtEpochSeconds += 100;
    await context.sendHalfwayNotificationIfNeeded(restored, "main");
    assert.equal(pushes.length, 2, "a new ride gets its own milestone");
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test("halfway does not notify for stale, completed, pickup or ended sessions", async () => {
  const { context, pushes } = serverHarness({ journeyNotificationReceipts: { entries: new Map(), sendOnce: () => assert.fail("must not send") } });
  const base = { ...session, scheduledJourneyPhase: "end", adHocJourneyId: "ride", rideStartedAtEpochSeconds: Date.now() / 1000 - 60,
    journeyProgress: { percent: 55, updatedAtEpochSeconds: Date.now() / 1000 } };
  for (const state of [base, { ...base, scheduledJourneyPhase: "start" },
    { ...base, journeyProgress: { ...base.journeyProgress, percent: 100 } },
    { ...base, journeyProgress: { ...base.journeyProgress, updatedAtEpochSeconds: 1 } }]) {
    await context.sendHalfwayNotificationIfNeeded(state, "main");
  }
  assert.equal(pushes.length, 0);
});

function routeHarness(context, route, nextRoute) {
  let handler;
  context.app = { post: (_path, action) => { handler = action; } };
  const start = source.indexOf(`app.post("${route}"`);
  const end = source.indexOf(`app.post("${nextRoute}"`, start);
  vm.runInContext(source.slice(start, end), context);
  return async body => {
    const response = { statusCode: 200, status(value) { this.statusCode = value; return this; }, json(value) { this.body = value; return this; } };
    await handler({ body, headers: {} }, response);
    return response;
  };
}

test("arrival content endpoint composes one message without sending any remote alert", async () => {
  const { context, pushes } = serverHarness({
    sanitizeJourneyDock: dock => dock?.id ? dock : null,
    deviceIdFromRequest: req => req.body.deviceId,
    validateDockPreferences: value => ({ value }),
  });
  const call = routeHarness(context, "/live-activity/arrival-message", "/live-activity/start-arrival");
  const response = await call({ deviceId: "device", startDock: { id: "start", name: "Home" },
    endDock: { id: "main", name: "Office" }, dockPreferences: preferences });
  assert.equal(response.statusCode, 200);
  assert.equal(response.body.title, "Journey to Office");
  assert.match(response.body.body, /^You’ve reached Home\. Office has 2 spaces available\. Alternatives:/);
  assert.equal(pushes.length, 0);
  const invalid = await call({ deviceId: "device" });
  assert.equal(invalid.statusCode, 400);
});

test("local arrival suppresses remote migration alert; manual/older clients get one combined snapshot", async () => {
  for (const arrivalNotificationHandled of [true, false, undefined]) {
    const state = { ...session, deviceId: "device", primaryDisplay: "spaces", scheduledJourneyPhase: "start" };
    const pollers = new Map([["start", { tokens: new Map([["token", state]]) }]]);
    const { context, pushes } = serverHarness({
      dockPollers: pollers, deviceIdFromRequest: () => "device",
      updateDeviceSessionDockPreferences: async () => {},
      scheduledJourneyPhaseFromValues: value => value,
      rideStartedAtForPhase: require("../journey-progress").rideStartedAtForPhase,
      updateJourneyProgress: require("../journey-progress").updateJourneyProgress,
      stopPollingForDock: dockId => pollers.delete(dockId), startPollingForDock() {},
      refreshSessionDockPreferences: async () => {},
      contentStateWithAlternatives: data => data,
      sendApnsPush: async () => ({ buildType: "production" }),
      updateLiveActivitiesActiveGauge() {}, DESTINATION_AVAILABILITY_GENERIC_ALERT_SUPPRESSION_MS: 120000,
      logger: { info() {}, warn() {}, error: message => assert.fail(message) },
    });
    context.sendHalfwayNotificationIfNeeded = async () => {};
    const call = routeHarness(context, "/live-activity/session/update", "/live-activity/end");
    const response = await call({ dockId: "start", targetDockId: "main", dockName: "Office",
      pushToken: "token", scheduledJourneyPhase: "end", arrivalNotificationHandled });
    assert.equal(response.statusCode, 200);
    assert.equal(response.body.migrated, true);
    assert.equal(pollers.get("main").tokens.get("token"), state);
    assert.equal(pushes.length, arrivalNotificationHandled ? 0 : 1);
    if (pushes.length) assert.match(pushes[0][3], /^Office has 2 spaces available\. Alternatives:/);
  }
});


test("catalogue used by consolidated alternatives still avoids unsupported query parameters", async () => {
  const requests = [];
  const { context, pushes } = serverHarness({
    createDockSnapshotLoader, POLL_INTERVAL_MS: 15000, AbortSignal,
    dockOverrides: new Map(),
    fetchTflJson: async (url, query = {}) => {
      requests.push({ url, query });
      if (url !== "/BikePoint" || Object.keys(query).length) throw new Error("Unsupported catalogue query");
      return docks.map(dock => ({ id: dock.id, commonName: dock.dockName, lat: dock.latitude, lon: dock.longitude,
        additionalProperties: Object.entries({ Installed: "true", Locked: "false",
          NbStandardBikes: String(dock.standardBikes || 0), NbEBikes: String(dock.eBikes || 0),
          NbEmptyDocks: String(dock.emptySpaces || 0) }).map(([key, value]) => ({ key, value })),
      }));
    },
  });
  for (const name of ["parseBikePointData", "effectiveDockDataForDock"]) {
    vm.runInContext(source.match(new RegExp(`function ${name}\\([^]*?\\n\\}(?=\\n|$)`))[0], context);
  }
  vm.runInContext(source.match(/const loadAlternativeDockSnapshots = createDockSnapshotLoader\([^]*?\n\}, POLL_INTERVAL_MS\);/)[0], context);
  await context.sendScheduledJourneyDestinationAvailabilityPushForSession(session, "main", "Office", { emptySpaces: 2 });
  assert.equal(pushes.length, 1);
  assert.match(pushes[0][3], /Alternatives: Station has 0 spaces;/);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "/BikePoint");
  assert.equal(Object.keys(requests[0].query).length, 0);
});

test("halfway preparation cannot notify after progress reaches completion", async () => {
  const state = { ...session, scheduledJourneyPhase: "end", adHocJourneyId: "ride", rideStartedAtEpochSeconds: Date.now() / 1000 - 60,
    journeyProgress: { percent: 55, updatedAtEpochSeconds: Date.now() / 1000 } };
  const { context, pushes } = serverHarness({
    dockPollers: new Map([["main", { tokens: new Map([["token", state]]) }]]),
    fetchNotificationDockData: async () => { state.journeyProgress.percent = 100; return { emptySpaces: 2 }; },
    journeyNotificationReceipts: { entries: new Map(), sendOnce: () => assert.fail("must not send") },
  });
  await context.sendHalfwayNotificationIfNeeded(state, "main");
  assert.equal(pushes.length, 0);
});

test("healthy scheduled starts and failed availability fetches each produce one truthful start alert", async () => {
  for (const unavailable of [false, true]) {
    const payloads = [];
    const { context } = serverHarness({
      fetchNotificationDockData: async () => {
        if (unavailable) throw new Error("offline");
        return { standardBikes: 8, eBikes: 2, emptySpaces: 4 };
      },
      refreshSessionDockPreferences: async () => {}, LIVE_ACTIVITY_STALE_AFTER_SECONDS: 120,
      APNS_TOPIC: "test.push-type.liveactivity", recordPushEvent() {}, apnsPushesTotal: { inc() {} },
      sendApnsRequestWithFallback: async (_token, _build, payload) => { payloads.push(JSON.parse(payload)); return { statusCode: 200, buildType: "production" }; },
    });
    await context.sendScheduledJourneyStartPush({ _id: "journey", pushToStartToken: "token", bikeDataFilter: "both",
      startDock: { id: "main", name: "Home" }, endDock: { id: "end", name: "Office" } });
    assert.equal(payloads.length, 1);
    assert.equal(payloads[0].aps.alert.title, "Journey to Office");
    assert.equal(payloads[0].aps.alert.body, unavailable
      ? "Bike availability at Home is currently unavailable. Live updates have started."
      : "Home has 8 bikes and 2 e-bikes available. Live updates have started.");
  }
});
