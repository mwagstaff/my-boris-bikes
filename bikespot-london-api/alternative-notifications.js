const { hasCustomAlternatives, compactPushDockText } = require("./dock-preferences");

function availability(dock, display) {
  if (display === "spaces") return dock.emptySpaces;
  if (display === "eBikes") return dock.eBikes;
  if (display === "allBikes") return dock.standardBikes + dock.eBikes;
  return dock.standardBikes;
}

function distance(origin, dock) {
  const radians = Math.PI / 180;
  const latitude = (dock.latitude - origin.latitude) * radians;
  const longitude = (dock.longitude - origin.longitude) * radians;
  return Math.sin(latitude / 2) ** 2 + Math.cos(origin.latitude * radians) *
    Math.cos(dock.latitude * radians) * Math.sin(longitude / 2) ** 2;
}

function buildAlternativeNotification({ dockId, primaryDisplay, preferences, docksById }) {
  let candidates;
  if (hasCustomAlternatives(preferences, dockId)) {
    // Saved order takes priority even when a chosen dock has no availability.
    candidates = preferences.alternatives[dockId].map((id) => docksById.get(id));
  } else {
    const origin = docksById.get(dockId);
    if (!origin || !Number.isFinite(origin.latitude) || !Number.isFinite(origin.longitude)) return null;
    candidates = [...docksById.values()]
      .filter((dock) => Number.isFinite(dock.latitude) && Number.isFinite(dock.longitude) &&
        availability(dock, primaryDisplay) > 0)
      .sort((a, b) => distance(origin, a) - distance(origin, b));
  }
  const seen = new Set([dockId]);
  const alternatives = candidates.filter((dock) => {
    if (!dock || !dock.isAvailable || seen.has(dock.id)) return false;
    seen.add(dock.id);
    return Number.isFinite(availability(dock, primaryDisplay));
  }).slice(0, 3);
  if (!alternatives.length) return null;
  const metric = primaryDisplay === "spaces" ? "space" : primaryDisplay === "eBikes" ? "e-bike" : "bike";
  return "Alternatives: " + alternatives.map((dock) => {
    const name = compactPushDockText(preferences?.aliases?.[dock.id] || dock.dockName || dock.name);
    const count = availability(dock, primaryDisplay);
    return `${name} - ${count} ${metric}${count === 1 ? "" : "s"}`;
  }).join("; ");
}

module.exports = { buildAlternativeNotification };
