// Loopback-only fixture for the standalone Swift cache checks. No production server or credentials.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const directory = path.join(__dirname, "../../bikespot-london-api/data/backgrounds");
// Keep bundle-reuse checks tied to the actual app bundle as the server collection grows.
const seed = JSON.parse(fs.readFileSync(path.join(__dirname, "../BikeSpot London/BikeSpot London/LondonBackgrounds.json")));
const bytes = seed.images.slice(0, 2).map(entry => fs.readFileSync(path.join(directory, entry.file)));
const entries = bytes.map(data => {
  const sha256 = crypto.createHash("sha256").update(data).digest("hex");
  return { id: "remote-landmark", sha256, byteCount: data.length, file: `remote-landmark-${sha256}.jpg` };
});
let mode = "valid";
let catalogRequests = 0;
let imageRequests = 0;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  const json = value => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(value)); };
  if (url.pathname === "/control") { mode = url.searchParams.get("mode"); return json({ mode }); }
  if (url.pathname === "/stats") return json({ catalogRequests, imageRequests });
  if (url.pathname === "/backgrounds") {
    catalogRequests++;
    if (mode === "offline") { res.statusCode = 503; return res.end(); }
    if (mode === "invalid") return res.end('{"schemaVersion":99,"images":[]}');
    if (mode === "bundled") return json(seed);
    if (mode === "slow") return setTimeout(() => json({ schemaVersion: 1, images: [entries[0]] }), 2000);
    return json({ schemaVersion: 1, images: [entries[mode === "updated" ? 1 : 0]] });
  }
  if (url.pathname.startsWith("/backgrounds/images/")) {
    imageRequests++;
    if (mode === "offline") { res.statusCode = 503; return res.end(); }
    const bundled = seed.images.find(entry => url.pathname.endsWith(entry.file));
    if (bundled) {
      const data = fs.readFileSync(path.join(directory, bundled.file));
      res.setHeader("Content-Type", "image/jpeg");
      if (mode === "slow-image") return setTimeout(() => res.end(data), 2000);
      return res.end(data);
    }
    const index = entries.findIndex(entry => url.pathname.endsWith(entry.file));
    if (index < 0) { res.statusCode = 404; return res.end(); }
    if (mode === "oversized") return res.end(Buffer.alloc(6 * 1024 * 1024));
    res.setHeader("Content-Type", "image/jpeg");
    return res.end(mode === "corrupt" ? Buffer.alloc(bytes[index].length) : bytes[index]);
  }
  res.statusCode = 404;
  res.end();
});
server.listen(0, "127.0.0.1", () => console.log(`http://127.0.0.1:${server.address().port}`));
