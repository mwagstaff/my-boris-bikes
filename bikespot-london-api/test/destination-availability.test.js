const test = require("node:test");
const assert = require("node:assert/strict");
const {
  fetchVerifiedDestinationAvailability,
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
