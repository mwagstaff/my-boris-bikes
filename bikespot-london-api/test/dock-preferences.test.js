const test = require("node:test");
const assert = require("node:assert/strict");
const {
  validateDockPreferences,
  storeDockPreferences,
  hasCustomAlternatives,
  resolveAlternatives,
  createDockSnapshotLoader,
  compactPushDockText,
} = require("../dock-preferences");

const primary = "BikePoints_1";
const second = "BikePoints_2";
const third = "BikePoints_3";
const fourth = "BikePoints_4";
function preferences(overrides = {}) {
  return {
    revision: 100,
    alternatives: { [primary]: [third, second] },
    aliases: { [third]: "By the park" },
    settings: { enabled: true, minSpaces: 3, minBikes: 3, minEBikes: 3, maxCount: 3, useMinimumThresholds: false },
    ...overrides,
  };
}
function dock(id, overrides = {}) {
  return { id, dockName: `Official ${id}`, standardBikes: 4, eBikes: 4, emptySpaces: 4, isAvailable: true, ...overrides };
}
function resolve(prefs, overrides = {}) {
  return resolveAlternatives({
    dockId: primary,
    preferences: prefs,
    primaryData: { standardBikes: 0, eBikes: 0, emptySpaces: 0 },
    primaryDisplay: "bikes",
    docksById: new Map([second, third, fourth].map((id) => [id, dock(id)])),
    automaticAlternatives: [dock(fourth)],
    ...overrides,
  });
}

test("validates a complete snapshot, dedupes in order, and preserves explicit empty lists", () => {
  const result = validateDockPreferences(preferences({
    alternatives: { [primary]: [third, primary, third, second], [second]: [] },
    aliases: { [third]: "  By the park  ", [second]: " " },
  }));
  assert.equal(result.error, undefined);
  assert.deepEqual(result.value.alternatives, { [primary]: [third, second], [second]: [] });
  assert.deepEqual(result.value.aliases, { [third]: "By the park" });
  assert.equal(hasCustomAlternatives(result.value, second), true);
  assert.equal(hasCustomAlternatives(result.value, third), false);
});

test("rejects malformed IDs, lists, settings and revisions instead of saving partial preferences", () => {
  for (const raw of [
    null,
    preferences({ revision: NaN }),
    preferences({ revision: 1.5 }),
    preferences({ revision: -1 }),
    preferences({ aliases: [] }),
    preferences({ aliases: { [second]: 12 } }),
    preferences({ alternatives: { [primary]: ["../../token"] } }),
    preferences({ alternatives: { [primary]: null } }),
    preferences({ settings: { ...preferences().settings, maxCount: 0 } }),
    preferences({ settings: { ...preferences().settings, enabled: "true" } }),
  ]) assert.ok(validateDockPreferences(raw).error);
});

test("custom alternatives keep saved order, official names, shared aliases and never add automatic filler", () => {
  const result = resolve(preferences());
  assert.deepEqual(result.map((value) => value.id), [third, second]);
  assert.equal(result[0].name, `Official ${third}`);
  assert.equal(result[0].alias, "By the park");
  assert.equal(result[1].alias, null);
  assert.deepEqual(resolve(preferences({ alternatives: { [primary]: [] } })), []);
});

test("missing preferences retain legacy automatic snapshots and reset restores automatic selection", () => {
  const legacy = { name: "Older client", standardBikes: 1, eBikes: 2, emptySpaces: 3 };
  assert.deepEqual(resolve(null, { automaticAlternatives: [legacy] }), [legacy]);
  assert.deepEqual(resolve(preferences({ alternatives: {} })).map((value) => value.id), [fourth]);
});

test("availability filtering happens before truncation without changing saved membership", () => {
  const prefs = preferences({ alternatives: { [primary]: [third, second, fourth] } });
  prefs.settings.maxCount = 1;
  const docksById = new Map([
    [third, dock(third, { standardBikes: 0 })],
    [second, dock(second, { isAvailable: false })],
    [fourth, dock(fourth)],
  ]);
  assert.deepEqual(resolve(prefs, { docksById }).map((value) => value.id), [fourth]);
  assert.deepEqual(prefs.alternatives[primary], [third, second, fourth]);
  docksById.set(third, dock(third));
  assert.deepEqual(resolve(prefs, { docksById }).map((value) => value.id), [third]);
});

test("visibility settings, primary thresholds and all-bike minimums match app behaviour", () => {
  const prefs = preferences();
  prefs.settings.enabled = false;
  assert.deepEqual(resolve(prefs), []);
  assert.deepEqual(resolve({ ...prefs, alternatives: {} }), []);
  prefs.settings.enabled = true;
  assert.deepEqual(resolve(prefs, { primaryData: dock(primary) }), []);
  prefs.settings.useMinimumThresholds = true;
  const docksById = new Map([
    [third, dock(third, { eBikes: 0 })],
    [second, dock(second)],
  ]);
  assert.deepEqual(resolve(prefs, { primaryDisplay: "allBikes", docksById }).map((value) => value.id), [second]);
  prefs.settings.useMinimumThresholds = false;
  assert.deepEqual(resolve(prefs, { primaryDisplay: "allBikes", docksById }).map((value) => value.id), [third, second]);
});

test("start and destination use independent dock lists and the correct availability metric", () => {
  const prefs = preferences({ alternatives: { [primary]: [second], [second]: [third] } });
  const docksById = new Map([
    [second, dock(second)],
    [third, dock(third, { standardBikes: 0, emptySpaces: 1 })],
  ]);
  assert.deepEqual(resolve(prefs, { docksById }).map((value) => value.id), [second]);
  assert.deepEqual(resolve(prefs, { dockId: second, primaryDisplay: "spaces", docksById }).map((value) => value.id), [third]);
});

test("aliases and live availability refresh by stable ID and removing an alias clears it", () => {
  const prefs = preferences({ alternatives: {} });
  const automaticAlternatives = [{ ...dock(third), name: "Old name", alias: "Old alias" }];
  const docksById = new Map([[third, dock(third, { dockName: "Renamed official dock", standardBikes: 7 })]]);
  const result = resolve(prefs, { automaticAlternatives, docksById });
  assert.equal(result[0].name, "Renamed official dock");
  assert.equal(result[0].standardBikes, 7);
  assert.equal(result[0].alias, "By the park");
  prefs.aliases = {};
  assert.equal(resolve(prefs, { automaticAlternatives, docksById })[0].alias, null);
});

test("saved lists may be longer than the Live Activity's display limit", () => {
  const ids = Array.from({ length: 8 }, (_, index) => `BikePoints_${index + 10}`);
  const prefs = preferences({ alternatives: { [primary]: ids } });
  prefs.settings.maxCount = 8;
  const result = resolve(prefs, { docksById: new Map(ids.map((id) => [id, dock(id)])) });
  assert.deepEqual(result.map((value) => value.id), ids.slice(0, 5));
  assert.deepEqual(prefs.alternatives[primary], ids);
});

test("per-device persistence rejects older or equal revisions and omitted legacy fields preserve values", async () => {
  let saved = null;
  const collection = {
    async updateOne() {},
    async findOneAndUpdate(query, update) {
      assert.equal(query.deviceId, "device-one");
      const requestedRevision = query.$or[0]["dockPreferences.revision"].$lt;
      if (saved && saved.revision >= requestedRevision) return null;
      saved = update.$set.dockPreferences;
      return { dockPreferences: saved };
    },
    async findOne() { return saved ? { dockPreferences: saved } : null; },
  };
  assert.equal(await storeDockPreferences(collection, "device-one"), null);
  const newest = preferences({ revision: 200 });
  assert.equal(await storeDockPreferences(collection, "device-one", newest), newest);
  assert.equal(await storeDockPreferences(collection, "device-one", preferences({ revision: 100 })), newest);
  assert.equal(await storeDockPreferences(collection, "device-one", preferences({ revision: 200, aliases: {} })), newest);
  assert.equal(await storeDockPreferences(collection, "device-one"), newest);
  const reset = preferences({ revision: 201, alternatives: {}, aliases: {} });
  assert.equal(await storeDockPreferences(collection, "device-one", reset), reset);
});

test("catalogue refresh coalesces concurrent sessions and bounds requests by poll interval", async () => {
  let calls = 0;
  let time = 1000;
  const load = createDockSnapshotLoader(async () => { calls++; return [dock(second)]; }, 100, () => time);
  const results = await Promise.all([load(), load(), load()]);
  assert.equal(calls, 1);
  assert.equal(results[0], results[1]);
  await load();
  assert.equal(calls, 1);
  time += 100;
  await load();
  assert.equal(calls, 2);
});

test("simultaneous first registrations can share the newly created device record", async () => {
  const saved = preferences({ revision: 300 });
  const collection = {
    async updateOne() { throw Object.assign(new Error("Duplicate device record"), { code: 11000 }); },
    async findOneAndUpdate() { return null; },
    async findOne() { return { dockPreferences: saved }; },
  };
  assert.equal(await storeDockPreferences(collection, "device-one", preferences()), saved);
});

test("long existing aliases stay intact in storage and are compacted only for push snapshots", () => {
  const alias = "A".repeat(5000);
  const result = validateDockPreferences(preferences({ aliases: { [third]: alias } }));
  assert.equal(result.error, undefined);
  assert.equal(result.value.aliases[third], alias);
  assert.equal(resolve(result.value)[0].alias, alias.slice(0, 120));
});

test("multibyte push names and aliases fit 120 bytes without splitting Unicode scalars", () => {
  for (const text of ["🚲".repeat(50), "駅".repeat(50), "é".repeat(100), "A".repeat(119) + "🚲"]) {
    const compacted = compactPushDockText(text);
    assert.ok(Buffer.byteLength(compacted, "utf8") <= 120);
    assert.equal(Buffer.from(compacted, "utf8").toString("utf8"), compacted);
    assert.ok(text.startsWith(compacted));
    const nextCharacter = [...text.slice(compacted.length)][0];
    assert.ok(Buffer.byteLength(compacted + nextCharacter, "utf8") > 120);
  }
  const text = "🚲".repeat(1000);
  const prefs = validateDockPreferences(preferences({ aliases: { [third]: text } })).value;
  const result = resolve(prefs, { docksById: new Map([[third, dock(third, { dockName: text })]]) });
  assert.equal(prefs.aliases[third], text);
  assert.equal(result[0].name, "🚲".repeat(30));
  assert.equal(result[0].alias, "🚲".repeat(30));
});

test("failed catalogue requests are bounded and retain the previous successful snapshot", async () => {
  let calls = 0;
  let time = 1000;
  const load = createDockSnapshotLoader(async () => {
    if (++calls > 1) throw new Error("TfL unavailable");
    return [dock(second)];
  }, 100, () => time);
  await load();
  time += 100;
  const results = await Promise.allSettled([load(), load()]);
  assert.equal(results[0].status, "rejected");
  assert.equal(calls, 2);
  assert.equal((await load()).get(second).id, second);
  assert.equal(calls, 2);
});
