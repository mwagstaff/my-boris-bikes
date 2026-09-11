const test = require("node:test");
const assert = require("node:assert/strict");
const {
  manualScheduledJourneyRunKey,
  scheduledJourneyStartDecision,
  shouldEndScheduledJourneyWindow,
} = require("../scheduled-journey-scheduling");

const scheduledTime = new Date("2026-08-26T14:55:00Z");
const manuallyStartedAt = new Date("2026-08-26T10:49:28Z");

function afternoonJourney(overrides = {}) {
  return {
    enabled: true,
    weekdays: [1, 2, 3, 4, 5],
    startTime: "15:55",
    timezone: "Europe/London",
    pausedRunKeys: [],
    ...overrides,
  };
}

test("a completed early manual run does not consume the later scheduled run", () => {
  const manualRunKey = manualScheduledJourneyRunKey(
    manuallyStartedAt,
    "test-activation"
  );
  const decision = scheduledJourneyStartDecision(
    afternoonJourney({ pausedRunKeys: [manualRunKey] }),
    scheduledTime
  );

  assert.equal(decision.canStart, true);
  assert.equal(decision.reason, "eligible");
  assert.equal(decision.runKey, "2026-08-26:15:55");
});

test("an in-progress manual run still prevents a duplicate scheduled start", () => {
  const decision = scheduledJourneyStartDecision(
    afternoonJourney({
      activeRun: {
        phase: "end",
        startedAt: manuallyStartedAt,
        runKey: manualScheduledJourneyRunKey(manuallyStartedAt, "test-activation"),
      },
    }),
    scheduledTime
  );

  assert.equal(decision.canStart, false);
  assert.equal(decision.reason, "already_active_today");
});

test("a paused scheduled run remains blocked", () => {
  const decision = scheduledJourneyStartDecision(
    afternoonJourney({ pausedRunKeys: ["2026-08-26:15:55"] }),
    scheduledTime
  );

  assert.equal(decision.canStart, false);
  assert.equal(decision.reason, "run_paused");
});

function morningJourney(phase) {
  return {
    startTime: "08:30",
    endTime: "09:30",
    timezone: "Europe/London",
    activeRun: {
      phase,
      startedAt: new Date("2026-08-26T07:30:00Z"),
    },
  };
}

test("a journey that has not reached its start dock ends at the cutoff", () => {
  const shouldEnd = shouldEndScheduledJourneyWindow(
    morningJourney("start"),
    new Date("2026-08-26T08:30:00Z")
  );

  assert.equal(shouldEnd, true);
});

test("an in-progress journey remains active at the cutoff", () => {
  const shouldEnd = shouldEndScheduledJourneyWindow(
    morningJourney("end"),
    new Date("2026-08-26T08:30:00Z")
  );

  assert.equal(shouldEnd, false);
});

test("an in-progress journey remains active after the cutoff", () => {
  const shouldEnd = shouldEndScheduledJourneyWindow(
    morningJourney("end"),
    new Date("2026-08-26T10:30:00Z")
  );

  assert.equal(shouldEnd, false);
});
