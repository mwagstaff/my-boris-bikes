#!/usr/bin/env node
// Standalone operator tool: never imports or starts the API server.
const fs = require("node:fs");
const path = require("node:path");
const http2 = require("node:http2");
const { parseArgs } = require("node:util");
const { createInterface } = require("node:readline/promises");
const { spawnSync } = require("node:child_process");
const jwt = require("jsonwebtoken");

function remoteCommand(args) {
  const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
  return 'cd "$HOME/dev/boris-bikes-api" && node scripts/sample-notification.js ' + args.map(quote).join(" ");
}

function buildPayload(title, body) {
  if (typeof title !== "string" || !title.trim() || typeof body !== "string" || !body.trim()) {
    throw new Error("Title and body must both contain text.");
  }
  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" } });
  if (Buffer.byteLength(payload) > 4096) throw new Error("Notification exceeds the APNs 4096-byte limit.");
  return payload;
}

function sendSample({ token, environment, topic, authorization, payload }, connect = http2.connect) {
  if (!/^(?:[a-f0-9]{2})+$/i.test(token || "")) throw new Error("A hexadecimal app device token is required.");
  if (!["production", "development"].includes(environment)) throw new Error("Choose production or development.");
  if (!topic || topic.endsWith(".push-type.liveactivity")) throw new Error("Use the app bundle topic, not a Live Activity topic.");
  return new Promise((resolve, reject) => {
    const client = connect(environment === "production"
      ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com");
    const timer = setTimeout(() => finish(new Error("APNs request timed out; delivery is unknown.")), 15000);
    let finished = false;
    function finish(error, result) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      client.destroy();
      if (error) reject(error); else resolve(result);
    }
    client.on("error", error => finish(error));
    const request = client.request({
      ":method": "POST", ":path": `/3/device/${token}`,
      authorization: `bearer ${authorization}`,
      "apns-topic": topic, "apns-push-type": "alert",
      "apns-priority": "10", "apns-expiration": "0",
      "content-type": "application/json",
    });
    let status;
    let apnsId;
    let response = "";
    request.setEncoding("utf8");
    request.on("response", headers => { status = headers[":status"]; apnsId = headers["apns-id"]; });
    request.on("data", chunk => { response += chunk; });
    request.on("error", error => finish(error));
    request.on("end", () => finish(status === 200 ? null
      : new Error(`APNs rejected sample (${status}): ${response}`), { status, apnsId }));
    request.end(payload);
  });
}

async function main() {
  const { values } = parseArgs({ options: {
    title: { type: "string" }, body: { type: "string" },
    "token-file": { type: "string" }, environment: { type: "string" },
    "dry-run": { type: "boolean" }, help: { type: "boolean" },
    remote: { type: "string" }, check: { type: "boolean" },
  } });
  if (values.help) {
    console.log("Usage: node scripts/sample-notification.js [--remote sky] [--title TEXT --body TEXT] [--token-file PATH --environment production|development] [--dry-run | --check]\nUse --remote sky from your Mac to run on the configured BikeSpot host over SSH. Without text arguments, prompts for title/body. Without --token-file, select a registered device from COMPLICATION_TOKENS_PATH. A token file contains only the app device token. Uses the API's APNS_* environment variables/defaults. Dry run previews text; check verifies local credentials and registration files. Neither sends a notification.");
    return;
  }
  if (values.remote) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$/.test(values.remote)) throw new Error("Invalid SSH host.");
    const args = Object.entries(values).filter(([key]) => key !== "remote")
      .flatMap(([key, value]) => typeof value === "boolean" ? (value ? [`--${key}`] : []) : [`--${key}`, value]);
    const result = spawnSync("ssh", ["-o", "ConnectTimeout=10", ...(process.stdin.isTTY ? ["-t"] : []),
      values.remote, remoteCommand(args)], { stdio: "inherit" });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
    return;
  }
  const tokenPath = process.env.COMPLICATION_TOKENS_PATH || path.join(__dirname, "..", "complication-tokens.json");
  const keyPath = process.env.APNS_KEY_PATH || path.join(__dirname, "..", "certs", "APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8");
  if (!values["dry-run"] && !values["token-file"] && !fs.existsSync(tokenPath)) {
    throw new Error("This checkout has no registered-device file. From your Mac, rerun with --remote sky to use the BikeSpot server's devices and signing key.");
  }
  if (values.check) {
    fs.accessSync(keyPath, fs.constants.R_OK);
    const count = values["token-file"] ? (fs.accessSync(values["token-file"], fs.constants.R_OK), 1)
      : JSON.parse(fs.readFileSync(tokenPath, "utf8")).length;
    console.log(`Signing key readable; ${count} registered device token(s) available. No notification sent.`);
    return;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const ask = async question => {
    if (!process.stdin.isTTY) throw new Error("Interactive input requires a terminal; supply the command options instead.");
    return rl.question(question);
  };
  try {
    const title = values.title ?? await ask("Notification title: ");
    const body = values.body ?? await ask("Notification body: ");
    const payload = buildPayload(title, body);
    console.log(JSON.stringify(JSON.parse(payload), null, 2));
    if (values["dry-run"]) return;

    let token;
    let environment = values.environment;
    if (values["token-file"]) {
      token = fs.readFileSync(values["token-file"], "utf8").trim();
      environment ??= await ask("Environment (production for App Store/TestFlight, development for Xcode): ");
    } else {
      const entries = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
      if (!entries.length) throw new Error("No registered devices; supply --token-file and --environment.");
      entries.forEach(([value, meta], index) => console.log(`${index + 1}: ${value.slice(0, 8)}… (${meta.buildType}, registered ${new Date(meta.registeredAt).toISOString()})`));
      const choice = Number(await ask("Device number (match the token prefix to your device): "));
      if (!Number.isInteger(choice) || choice < 1 || choice > entries.length) throw new Error("Invalid device selection.");
      token = entries[choice - 1][0];
      environment ??= entries[choice - 1][1].buildType;
    }
    const authorization = jwt.sign({ iss: process.env.APNS_TEAM_ID || "SJ8X4DLAN9", iat: Math.floor(Date.now() / 1000) },
      fs.readFileSync(keyPath), { algorithm: "ES256", header: { kid: process.env.APNS_KEY_ID || "UQ2DV6UTF4" } });
    const topic = process.env.APNS_BACKGROUND_TOPIC_MY_BORIS_BIKES || process.env.APNS_BACKGROUND_TOPIC ||
      (process.env.APNS_TOPIC || "dev.skynolimit.myborisbikes.My-Boris-Bikes").replace(/\.push-type\.liveactivity$/, "");
    const result = await sendSample({ token, environment, topic, authorization, payload });
    console.log(`APNs accepted sample (${result.status}); ID: ${result.apnsId}. Check the iPhone to verify display and summary.`);
  } finally {
    rl.close();
  }
}

if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { buildPayload, sendSample, remoteCommand };
