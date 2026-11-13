const { test } = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { buildPayload, sendSample, remoteCommand } = require("../scripts/sample-notification");
const { spawnSync } = require("node:child_process");

test("remote text survives shell quoting without command substitution", () => {
  const body = "King's Road: $HOME `whoami` $(whoami)\nSecond line";
  const command = remoteCommand(["--body", body]);
  // Run just the quoted argument list through a shell; never invoke SSH or APNs.
  const quotedArgs = command.split("scripts/sample-notification.js ")[1];
  const result = spawnSync("sh", ["-c", `printf '%s\\n' ${quotedArgs}`], { encoding: "utf8" });
  assert.equal(result.status, 0);
  assert.equal(result.stdout, `--body\n${body}\n`);
});

test("sample text preserves punctuation and Unicode, rejects empty and oversized payloads", () => {
  const body = "Office: 5 spaces. King's Road: 3 spaces. 🚲";
  assert.equal(JSON.parse(buildPayload("Journey", body)).aps.alert.body, body);
  assert.throws(() => buildPayload(" ", body), /contain text/);
  assert.throws(() => buildPayload("Journey", "🚲".repeat(1100)), /4096-byte/);
});

test("sample sends one regular app alert, with no journey mutation payload or stale delivery", async () => {
  let sent;
  let destroyed = false;
  const result = await sendSample({ token: "ab".repeat(32), environment: "production",
    topic: "example.bikespot", authorization: "test", payload: buildPayload("Arrival", "5 spaces at Office.") }, host => {
    assert.equal(host, "https://api.push.apple.com");
    const client = new EventEmitter();
    client.destroy = () => { destroyed = true; };
    client.request = headers => {
      assert.equal(headers["apns-topic"], "example.bikespot");
      assert.equal(headers["apns-push-type"], "alert");
      assert.equal(headers["apns-expiration"], "0");
      const request = new EventEmitter();
      request.setEncoding = () => {};
      request.end = payload => {
        sent = JSON.parse(payload);
        process.nextTick(() => {
          request.emit("response", { ":status": 200, "apns-id": "sample-id" });
          request.emit("end");
        });
      };
      return request;
    };
    return client;
  });
  assert.deepEqual(Object.keys(sent), ["aps"]);
  assert.equal(sent.aps.alert.body, "5 spaces at Office.");
  assert.equal(result.apnsId, "sample-id");
  assert.equal(destroyed, true);
});

test("invalid targeting is rejected before network access", () => {
  const connect = () => assert.fail("must not connect");
  const options = { token: "ab".repeat(32), environment: "production", topic: "example.bikespot" };
  assert.throws(() => sendSample({ ...options, environment: "prod" }, connect), /production or development/);
  assert.throws(() => sendSample({ ...options, token: "not-a-token" }, connect), /hexadecimal/);
  assert.throws(() => sendSample({ ...options, topic: "example.bikespot.push-type.liveactivity" }, connect), /app bundle/);
});

test("APNs rejection is reported, without retrying or selecting another device", async () => {
  let requests = 0;
  await assert.rejects(sendSample({ token: "ab".repeat(32), environment: "development",
    topic: "example.bikespot", authorization: "test", payload: buildPayload("Test", "Test") }, host => {
    assert.equal(host, "https://api.sandbox.push.apple.com");
    const client = new EventEmitter();
    client.destroy = () => {};
    client.request = () => {
      requests++;
      const request = new EventEmitter();
      request.setEncoding = () => {};
      request.end = () => process.nextTick(() => {
        request.emit("response", { ":status": 400 });
        request.emit("data", '{"reason":"BadDeviceToken"}');
        request.emit("end");
      });
      return request;
    };
    return client;
  }), /BadDeviceToken/);
  assert.equal(requests, 1);
});
