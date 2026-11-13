const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { JourneyNotificationReceipts } = require("../journey-notification-receipts");

test("only explicit APNs rejections release a milestone for retry", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "bikespot-receipts-"));
  try {
    const receipts = new JourneyNotificationReceipts(path.join(directory, "receipts.json"));
    await assert.rejects(receipts.sendOnce("rejected", async () => {
      throw Object.assign(new Error("unavailable"), { apns: { statusCode: 503 } });
    }));
    let sends = 0;
    assert.equal(await receipts.sendOnce("rejected", async () => { sends++; }), true);
    await assert.rejects(receipts.sendOnce("ambiguous", async () => { throw new Error("connection lost"); }));
    const restored = new JourneyNotificationReceipts(receipts.file);
    assert.equal(await restored.sendOnce("ambiguous", async () => { sends++; }), false);
    assert.equal(await restored.sendOnce("rejected", async () => { sends++; }), false);
    assert.equal(sends, 1);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test("a failed durable claim cannot send an untracked milestone", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "bikespot-receipts-"));
  try {
    const receipts = new JourneyNotificationReceipts(path.join(directory, "missing", "receipts.json"));
    await assert.rejects(receipts.sendOnce("ride", async () => assert.fail("must not send")));
    assert.equal(receipts.entries.has("ride"), false);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
