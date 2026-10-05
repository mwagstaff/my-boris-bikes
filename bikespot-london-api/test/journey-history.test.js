const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(require.resolve("../server.js"), "utf8");
const historyCode = source.slice(source.indexOf("async function archiveScheduledJourneyRun("), source.indexOf("async function completeScheduledJourneyFromArrivalSession("))
  + source.slice(source.indexOf('app.get("/journey-history"'), source.indexOf('app.get("/scheduled-journeys"'));

function fixture() {
  const stored = new Map();
  let handler;
  const collection = {
    async updateOne(query, update) {
      if (!stored.has(query._id)) stored.set(query._id, { _id: query._id, ...update.$setOnInsert });
    },
    find(query) {
      let rows = [...stored.values()].filter(row => row.deviceId === query.deviceId);
      if (query.$or) {
        const before = query.$or[0].startedAt.$lt;
        const id = query.$or[1]._id.$gt;
        rows = rows.filter(row => row.startedAt < before || (+row.startedAt === +before && row._id > id));
      }
      return { sort() { rows.sort((a, b) => b.startedAt - a.startedAt || a._id.localeCompare(b._id)); return this; },
        limit(n) { rows = rows.slice(0, n); return this; }, async toArray() { return rows; } };
    },
  };
  const context = vm.createContext({ journeyHistoryCollection: collection, Date,
    requireScheduledJourneysCollection: async () => ({}), deviceIdFromRequest: req => req.query.deviceId,
    app: { get(_path, callback) { handler = callback; } } });
  vm.runInContext(historyCode, context);
  async function get(query) {
    let status = 200, body;
    await handler({ query }, { status(value) { status = value; return this; }, json(value) { body = value; } });
    return { status, body };
  }
  return { stored, archive: context.archiveScheduledJourneyRun, get };
}

const journey = (runKey, deviceId = "device") => ({ _id: "route", deviceId,
  startDock: { id: "start" }, endDock: { id: "end" },
  activeRun: { runKey, startedAt: new Date("2026-08-07T12:40:00.123Z") } });

test("archive preserves each occurrence and does not overwrite its original end", async () => {
  const f = fixture();
  const endedAt = new Date("2026-08-07T13:02:00Z");
  await f.archive(journey("one"), endedAt);
  await f.archive(journey("one"), new Date());
  await f.archive(journey("two"), endedAt);
  await f.archive({ ...journey("none"), activeRun: null });
  assert.equal(f.stored.size, 2);
  assert.equal(+f.stored.get("scheduled-route-one").endedAt, +endedAt);
  assert.equal(f.stored.get("scheduled-route-one").kind, "scheduled");
});

test("history is device scoped and paginates tied timestamps without gaps", async () => {
  const f = fixture();
  for (let i = 0; i < 63; i++) await f.archive(journey(String(i).padStart(3, "0")));
  await f.archive(journey("private", "other-device"));
  const first = (await f.get({ deviceId: "device" })).body;
  assert.equal(first.entries.length, 50);
  assert.equal(first.hasMore, true);
  const last = first.entries.at(-1);
  const second = (await f.get({ deviceId: "device", before: last.startedAt.toISOString(), afterID: last.id })).body;
  assert.equal(second.entries.length, 13);
  assert.equal(second.hasMore, false);
  assert.equal(new Set([...first.entries, ...second.entries].map(row => row.id)).size, 63);
  assert.equal(first.entries[0].deviceId, undefined);
  assert.equal((await f.get({ deviceId: "device", before: "invalid", afterID: "id" })).status, 400);
  assert.equal((await f.get({})).status, 400);
});
