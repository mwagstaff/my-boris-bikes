const test = require("node:test");
const assert = require("node:assert/strict");
const { updateJourneyProgress } = require("../journey-progress");

test("progress updates retain availability and ignore out-of-order locations", () => {
  const session = { scheduledJourneyPhase: "end", emptySpaces: 8 };
  const progress = { percent: 42, remainingMeters: 920, updatedAtEpochSeconds: 1000 };
  assert.equal(updateJourneyProgress(session, progress, 1000), true);
  assert.equal(session.emptySpaces, 8);
  assert.equal(updateJourneyProgress(session, { ...progress, percent: 10, updatedAtEpochSeconds: 999 }, 1000), false);
  assert.deepEqual(session.journeyProgress, progress);
  // Moving away from the destination is valid; progress need not increase monotonically.
  assert.equal(updateJourneyProgress(session, { ...progress, percent: 35, updatedAtEpochSeconds: 1010 }, 1010), true);
});

test("pickup, stale, future and malformed progress are rejected", () => {
  const progress = { percent: 42, remainingMeters: 920, updatedAtEpochSeconds: 1000 };
  assert.equal(updateJourneyProgress({ scheduledJourneyPhase: "start" }, progress, 1000), false);
  for (const value of [null, {}, { ...progress, percent: 101 }, { ...progress, percent: "42" },
    { ...progress, remainingMeters: -1 }, { ...progress, remainingMeters: Infinity },
    { ...progress, updatedAtEpochSeconds: 879 }, { ...progress, updatedAtEpochSeconds: 1011 }]) {
    assert.equal(updateJourneyProgress({ scheduledJourneyPhase: "end" }, value, 1000), false);
  }
});
