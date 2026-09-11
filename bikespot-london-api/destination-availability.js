async function fetchVerifiedDestinationAvailability(fetchDockData, dockId) {
  try {
    return { data: await fetchDockData(dockId), error: null };
  } catch (error) {
    return { data: null, error };
  }
}

module.exports = { fetchVerifiedDestinationAvailability };
