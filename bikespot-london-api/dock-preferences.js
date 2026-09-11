const MAX_DOCKS = 2000;
const MAX_ALTERNATIVES_PER_DOCK = 2000;
const MAX_LIVE_ACTIVITY_ALTERNATIVES = 5;
const MAX_PUSH_DOCK_TEXT_BYTES = 120;
const own = (object, key) => Object.prototype.hasOwnProperty.call(object || {}, key);
const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const validDockId = (value) => typeof value === "string" && /^BikePoints_\d+$/.test(value);

// Validate the complete snapshot before saving: malformed entries must never
// silently turn a custom list into automatic suggestions or remove an alias.
function validateDockPreferences(raw) {
  if (!isRecord(raw) || !Number.isSafeInteger(raw.revision) || raw.revision < 0) {
    return { error: "dockPreferences.revision must be a non-negative safe integer" };
  }
  if (!isRecord(raw.alternatives) || !isRecord(raw.aliases) || !isRecord(raw.settings)) {
    return { error: "dockPreferences requires alternatives, aliases, and settings objects" };
  }
  if (Object.keys(raw.alternatives).length > MAX_DOCKS || Object.keys(raw.aliases).length > MAX_DOCKS) {
    return { error: "Too many dock preferences" };
  }
  const alternatives = {};
  for (const [dockId, ids] of Object.entries(raw.alternatives)) {
    if (!validDockId(dockId) || !Array.isArray(ids) || ids.length > MAX_ALTERNATIVES_PER_DOCK || !ids.every(validDockId)) {
      return { error: "Alternative lists must contain valid BikePoint IDs" };
    }
    alternatives[dockId] = [...new Set(ids)].filter((id) => id !== dockId);
  }
  const aliases = {};
  for (const [dockId, alias] of Object.entries(raw.aliases)) {
    if (!validDockId(dockId) || typeof alias !== "string") {
      return { error: "Dock aliases must be strings with valid BikePoint IDs" };
    }
    if (alias.trim()) aliases[dockId] = alias.trim();
  }
  const settings = raw.settings;
  if (typeof settings.enabled !== "boolean" || typeof settings.useMinimumThresholds !== "boolean" ||
      !["minSpaces", "minBikes", "minEBikes", "maxCount"].every((key) =>
        Number.isSafeInteger(settings[key]) && settings[key] >= (key === "maxCount" ? 1 : 0) && settings[key] <= MAX_DOCKS)) {
    return { error: "Invalid alternative dock settings" };
  }
  return { value: {
    revision: raw.revision,
    alternatives,
    aliases,
    settings: {
      enabled: settings.enabled,
      minSpaces: settings.minSpaces,
      minBikes: settings.minBikes,
      minEBikes: settings.minEBikes,
      maxCount: settings.maxCount,
      useMinimumThresholds: settings.useMinimumThresholds,
    },
  } };
}

async function storeDockPreferences(collection, deviceId, preferences) {
  if (preferences !== undefined) {
    // Ensure the unique device record exists, then conditionally update it. Two
    // concurrent requests cannot let an older revision overwrite the newer one.
    try {
      await collection.updateOne(
        { deviceId },
        { $setOnInsert: { deviceId } },
        { upsert: true }
      );
    } catch (error) {
      if (error.code !== 11000) throw error;
    }
    const accepted = await collection.findOneAndUpdate(
      { deviceId, $or: [
        { "dockPreferences.revision": { $lt: preferences.revision } },
        { dockPreferences: { $exists: false } },
      ] },
      { $set: { dockPreferences: preferences, updatedAt: new Date() } },
      { returnDocument: "after" }
    );
    if (accepted) return accepted.dockPreferences || null;
  }
  const current = await collection.findOne({ deviceId });
  return current?.dockPreferences || null;
}

function hasCustomAlternatives(preferences, dockId) {
  return own(preferences?.alternatives, dockId);
}

function shouldShowAlternatives(primaryData, purpose, settings) {
  if (!settings.enabled) return false;
  if (purpose === "spaces") return primaryData.emptySpaces < settings.minSpaces;
  if (purpose === "eBikes") return primaryData.eBikes < settings.minEBikes;
  if (purpose === "allBikes") {
    return primaryData.standardBikes < settings.minBikes || primaryData.eBikes < settings.minEBikes;
  }
  return primaryData.standardBikes < settings.minBikes;
}

function meetsRequirement(dock, purpose, settings) {
  if (settings.useMinimumThresholds) {
    if (purpose === "spaces") return dock.emptySpaces >= settings.minSpaces;
    if (purpose === "eBikes") return dock.eBikes >= settings.minEBikes;
    if (purpose === "allBikes") return dock.standardBikes >= settings.minBikes && dock.eBikes >= settings.minEBikes;
    return dock.standardBikes >= settings.minBikes;
  }
  if (purpose === "spaces") return dock.emptySpaces > 0;
  if (purpose === "eBikes") return dock.eBikes > 0;
  if (purpose === "allBikes") return dock.standardBikes + dock.eBikes > 0;
  return dock.standardBikes > 0;
}

// APNs has a byte limit, so keep complete Unicode scalars within the same
// 120-byte display budget as the app. Stored aliases remain unshortened.
function compactPushDockText(value) {
  if (typeof value !== "string") return "";
  let result = "";
  let bytes = 0;
  for (const character of value) {
    const length = Buffer.byteLength(character, "utf8");
    if (bytes + length > MAX_PUSH_DOCK_TEXT_BYTES) break;
    result += character;
    bytes += length;
  }
  return result;
}

function alternativeSnapshot(dock, aliases) {
  return {
    ...(dock.id ? { id: dock.id } : {}),
    name: compactPushDockText(dock.dockName || dock.name),
    ...(dock.id && aliases !== undefined
      ? { alias: compactPushDockText(aliases[dock.id]) || null }
      : dock.alias ? { alias: compactPushDockText(dock.alias) } : {}),
    standardBikes: dock.standardBikes,
    eBikes: dock.eBikes,
    emptySpaces: dock.emptySpaces,
  };
}

function resolveAlternatives({ dockId, preferences, primaryData, primaryDisplay, docksById = new Map(), automaticAlternatives = [] }) {
  if (preferences?.settings.enabled === false) return [];
  if (!hasCustomAlternatives(preferences, dockId)) {
    // Legacy automatic lists stay client-selected. Refresh modern snapshots by
    // identity while still accepting older snapshots which only have a name.
    return automaticAlternatives.slice(0, MAX_LIVE_ACTIVITY_ALTERNATIVES).map((dock) =>
      alternativeSnapshot(docksById.get(dock.id) || dock, preferences?.aliases));
  }
  const settings = preferences.settings;
  if (!shouldShowAlternatives(primaryData, primaryDisplay, settings)) return [];
  return preferences.alternatives[dockId]
    .map((id) => docksById.get(id))
    .filter((dock) => dock && dock.isAvailable && meetsRequirement(dock, primaryDisplay, settings))
    .slice(0, Math.min(settings.maxCount, MAX_LIVE_ACTIVITY_ALTERNATIVES))
    .map((dock) => alternativeSnapshot(dock, preferences.aliases));
}

// All sessions share one bounded refresh of the TfL catalogue per poll period.
// Failed requests are also coalesced so a TfL outage cannot cause a request storm.
function createDockSnapshotLoader(fetchDocks, ttlMs, now = Date.now) {
  let snapshot = new Map();
  let retryAt = 0;
  let pending = null;
  return async function loadDocks() {
    if (pending) return pending;
    if (now() < retryAt) return snapshot;
    retryAt = now() + ttlMs;
    pending = Promise.resolve().then(fetchDocks).then((docks) => {
      snapshot = new Map(docks.map((dock) => [dock.id, dock]));
      return snapshot;
    }).finally(() => { pending = null; });
    return pending;
  };
}

module.exports = {
  compactPushDockText,
  validateDockPreferences,
  storeDockPreferences,
  hasCustomAlternatives,
  resolveAlternatives,
  createDockSnapshotLoader,
};
