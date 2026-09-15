const test = require("node:test");
const assert = require("node:assert/strict");
const { rideStartedAtForPhase } = require("../journey-progress");

test("ride time starts on collection, not when pickup tracking began", () => {
  const pickup = { scheduledJourneyPhase: "start", startedAt: 1_000_000 };
  assert.equal(rideStartedAtForPhase("start", pickup, undefined, 2000), null);
  assert.equal(rideStartedAtForPhase("end", pickup, undefined, 2000), 2000);
});

test("registration and availability updates preserve the established clock", () => {
  const riding = { scheduledJourneyPhase: "end", rideStartedAtEpochSeconds: 1000 };
  assert.equal(rideStartedAtForPhase("end", riding, 1500, 2000), 1000);
  assert.equal(rideStartedAtForPhase("end", riding, undefined, 2000), 1000);
  assert.equal(rideStartedAtForPhase("start", riding, undefined, 2000), null);
});

test("accept actual phone collection time and reject invalid timestamps", () => {
  assert.equal(rideStartedAtForPhase("end", null, 1900, 2000), 1900);
  for (const value of [NaN, Infinity, -1, "1900", 2011, -30000]) {
    assert.equal(rideStartedAtForPhase("end", null, value, 2000), 2000);
  }
  assert.equal(rideStartedAtForPhase("end", null, 2005, 2000), 2000);
});

test("legacy riding payloads do not invent a new start time", () => {
  assert.equal(rideStartedAtForPhase("end", { scheduledJourneyPhase: "end" }, undefined, 2000), null);
});
