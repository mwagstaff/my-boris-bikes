// Resolve at presentation time; official names remain intact in stored routes.
function notificationDockName(preferences, dockId, fallback) {
  const alias = preferences?.aliases?.[dockId];
  return typeof alias === "string" && alias.trim() ? alias.trim() : fallback;
}

module.exports = { notificationDockName };
