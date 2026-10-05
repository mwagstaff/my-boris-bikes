const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const net = require("node:net");
const { spawn } = require("node:child_process");
const { once } = require("node:events");

test("server boots and registers history after Express initialization", { timeout: 15000 }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "bikespot-startup-"));
  const probe = net.createServer();
  probe.listen(0, "127.0.0.1");
  await once(probe, "listening");
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const key = path.join(directory, "test-key");
  fs.writeFileSync(key, "unused test key");
  const preload = path.join(directory, "offline.cjs");
  fs.writeFileSync(preload, 'global.fetch = async () => { throw new Error("Offline startup test"); };');
  const child = spawn(process.execPath, ["--require", preload, require.resolve("../server.js")], {
    // No production credentials, persisted sessions or external requests.
    env: { PATH: process.env.PATH, PORT: String(port), APNS_KEY_PATH: key, LOG_DIR: directory,
      COMPLICATION_TOKENS_PATH: path.join(directory, "tokens.json"),
      DOCK_OVERRIDES_PATH: path.join(directory, "overrides.json"),
      ARRIVAL_RECEIPTS_PATH: path.join(directory, "arrivals.json") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", data => { output += data; });
  child.stderr.on("data", data => { output += data; });
  try {
    let ready = false;
    for (let i = 0; i < 80; i++) {
      assert.equal(child.exitCode, null, output);
      try {
        const health = await fetch(`http://127.0.0.1:${port}/healthcheck`);
        if (health.ok) { ready = true; break; }
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.ok(ready, output);
    const history = await fetch(`http://127.0.0.1:${port}/journey-history?deviceId=startup-test`);
    // No database is configured; a registered handler returns 503, not an Express 404.
    assert.equal(history.status, 503);
    assert.equal(child.exitCode, null, output);
  } finally {
    if (child.exitCode === null) {
      child.kill("SIGTERM");
      await once(child, "exit");
    }
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
