const test = require("node:test");
const assert = require("node:assert/strict");
const {
  fetchVerifiedDestinationAvailability,
  fetchJourneyDestinationAvailability,
} = require("../destination-availability");

test("destination snapshots use freshly verified server availability", async () => {
  const result = await fetchVerifiedDestinationAvailability(
    async () => ({ standardBikes: 12, eBikes: 1, emptySpaces: 2 }),
    "BikePoints_112"
  );

  assert.deepEqual(result.data, {
    standardBikes: 12,
    eBikes: 1,
    emptySpaces: 2,
  });
  assert.equal(result.error, null);
});

test("a failed verification does not manufacture a zero-space snapshot", async () => {
  const failure = new Error("TfL unavailable");
  const result = await fetchVerifiedDestinationAvailability(
    async () => { throw failure; },
    "BikePoints_112"
  );

  assert.equal(result.data, null);
  assert.equal(result.error, failure);
});


test("collection destination snapshots include identity, alias, zero spaces and independent freshness", async () => {
  const session = { destinationDockId: "BikePoints_112", destinationDockName: "Station",
    dockPreferences: { aliases: { BikePoints_112: "Work" } } };
  const snapshot = await fetchJourneyDestinationAvailability(session, async (id) => {
    assert.equal(id, "BikePoints_112");
    return { emptySpaces: 0 };
  }, () => 200000);
  assert.deepEqual(snapshot, { id: "BikePoints_112", name: "Work", spaces: 0, updatedAtEpochSeconds: 200 });
});

test("destination failures retain the previous count and timestamp, but refresh its alias", async () => {
  const session = { destinationDockId: "BikePoints_112", destinationDockName: "Station",
    destinationAvailability: { id: "BikePoints_112", name: "Old name", spaces: 7, updatedAtEpochSeconds: 100 } };
  const snapshot = await fetchJourneyDestinationAvailability(session, async () => { throw new Error("Offline"); });
  assert.deepEqual(snapshot, { id: "BikePoints_112", name: "Station", spaces: 7, updatedAtEpochSeconds: 100 });
});

test("unknown or invalid destination counts never turn into zero or another dock's snapshot", async () => {
  const session = { destinationDockId: "BikePoints_112", destinationDockName: "Station",
    destinationAvailability: { id: "BikePoints_99", name: "Other", spaces: 3, updatedAtEpochSeconds: 100 } };
  for (const emptySpaces of [undefined, null, -1, NaN, "3"]) {
    assert.deepEqual(await fetchJourneyDestinationAvailability(session, async () => ({ emptySpaces })),
      { id: "BikePoints_112", name: "Station" });
  }
});
