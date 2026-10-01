const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync(require.resolve("../server"), "utf8");
function harness() {
  let now = 1_800_000_000_000;
  const context = vm.createContext({
    Date: class extends Date { static now() { return now; } },
    fetchTflJson: async () => ({}),
    effectiveDockDataForDock: () => ({ standardBikes: 2, eBikes: 0, emptySpaces: 5 }),
    sanitizePrimaryDisplay: (value) => value || "bikes",
    compactPushDockText: (value) => value,
  });
  for (const [start, end] of [
    ["async function fetchDockData(", "function parseBikePointData("],
    ["function contentStateWithAlternatives(", "// ── APNS Push"],
  ]) {
    vm.runInContext(source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start))), context);
  }
  return { context, advance: () => { now += 60_000; } };
}

test("cached pushes preserve the successful dock fetch time", async () => {
  const { context, advance } = harness();
  const data = await context.fetchDockData("BikePoints_1");
  const first = context.contentStateWithAlternatives(data, {});
  advance();
  const cached = context.contentStateWithAlternatives(data, {});
  assert.equal(cached.availabilityUpdatedAtEpochSeconds, first.availabilityUpdatedAtEpochSeconds);
  const fresh = context.contentStateWithAlternatives(await context.fetchDockData("BikePoints_1"), {});
  assert.equal(fresh.availabilityUpdatedAtEpochSeconds, first.availabilityUpdatedAtEpochSeconds + 60);
  assert.equal(fresh.standardBikes, 2);
});

test("client seeded counts without a fetch time do not pretend to be fresh", () => {
  const { context } = harness();
  const state = context.contentStateWithAlternatives({ standardBikes: 2, eBikes: 0, emptySpaces: 5 }, {});
  assert.equal(state.availabilityUpdatedAtEpochSeconds, null);
});
