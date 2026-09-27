const { compactPushDockText } = require("./dock-preferences");

async function fetchVerifiedDestinationAvailability(fetchDockData, dockId) {
  try {
    return { data: await fetchDockData(dockId), error: null };
  } catch (error) {
    return { data: null, error };
  }
}

async function fetchJourneyDestinationAvailability(session, fetchDockData, now = Date.now) {
  const id = session.destinationDockId;
  const name = compactPushDockText(session.dockPreferences?.aliases?.[id] || session.destinationDockName || id);
  const { data } = await fetchVerifiedDestinationAvailability(fetchDockData, id);
  if (Number.isInteger(data?.emptySpaces) && data.emptySpaces >= 0) {
    return { id, name, spaces: data.emptySpaces, updatedAtEpochSeconds: now() / 1000 };
  }
  // Keep the original retrieval time on failures, including alias-only changes.
  return session.destinationAvailability?.id === id
    ? { ...session.destinationAvailability, name } : { id, name };
}

module.exports = { fetchVerifiedDestinationAvailability, fetchJourneyDestinationAvailability };
