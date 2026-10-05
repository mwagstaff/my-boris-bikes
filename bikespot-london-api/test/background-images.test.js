const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const express = require("express");
const { once } = require("node:events");
const { registerBackgroundRoutes } = require("../background-images");
const { publishBackgrounds } = require("../scripts/publish-backgrounds");

test("backgrounds publish, update and retire without restarting the API", async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "bikespot-backgrounds-"));
  const source = path.join(root, "source");
  const destination = path.join(root, "published");
  await fs.mkdir(source);
  const realDirectory = path.join(__dirname, "../data/backgrounds");
  const realCatalog = JSON.parse(await fs.readFile(path.join(realDirectory, "catalog.json"), "utf8"));
  const firstBytes = await fs.readFile(path.join(realDirectory, realCatalog.images[0].file));
  const secondBytes = await fs.readFile(path.join(realDirectory, realCatalog.images[1].file));
  await fs.writeFile(path.join(source, "landmark.jpg"), firstBytes);
  const first = await publishBackgrounds(source, destination);
  const app = express();
  registerBackgroundRoutes(app, { directory: destination });
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(root, { recursive: true }); });
  const base = `http://127.0.0.1:${server.address().port}`;

  const manifest = await fetch(`${base}/backgrounds`);
  assert.equal(manifest.status, 200);
  assert.deepEqual(await manifest.json(), first);
  assert.equal(manifest.headers.get("cache-control"), "public, max-age=300");
  assert.equal((await fetch(`${base}/backgrounds`, { headers: {
    "If-None-Match": manifest.headers.get("etag"), "Cache-Control": "max-age=0",
  } })).status, 304);
  const image = await fetch(`${base}/backgrounds/images/${first.images[0].file}`);
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), firstBytes);
  assert.match(image.headers.get("cache-control"), /immutable/);
  assert.match(image.headers.get("content-type"), /image\/jpeg/);

  // Replacing the file keeps its stable ID but changes its immutable URL.
  await fs.writeFile(path.join(source, "landmark.jpg"), secondBytes);
  await fs.writeFile(path.join(source, "new-landmark.jpg"), firstBytes);
  const updated = await publishBackgrounds(source, destination);
  assert.equal(updated.images.length, 2);
  assert.equal(updated.images[0].id, first.images[0].id);
  assert.notEqual(updated.images[0].file, first.images[0].file);
  assert.deepEqual(await (await fetch(`${base}/backgrounds`)).json(), updated);
  assert.equal((await fetch(`${base}/backgrounds/images/${first.images[0].file}`)).status, 200);

  await fs.unlink(path.join(source, "landmark.jpg"));
  const retired = await publishBackgrounds(source, destination);
  assert.equal(retired.images.length, 1);
  assert.equal(retired.images[0].id, "new-landmark");

  // Bad publication never replaces the last good catalogue.
  await fs.writeFile(path.join(source, "invalid.jpg"), "not an image");
  await assert.rejects(publishBackgrounds(source, destination), /Expected JPEG/);
  assert.deepEqual(await (await fetch(`${base}/backgrounds`)).json(), retired);
  assert.equal((await fetch(`${base}/backgrounds/images/catalog.json`)).status, 404);
  assert.equal((await fetch(`${base}/backgrounds/images/..%2Fcatalog.json`)).status, 404);

  await fs.writeFile(path.join(destination, "catalog.json"), "broken json");
  const broken = await fetch(`${base}/backgrounds`);
  assert.equal(broken.status, 503);
  assert.equal(broken.headers.get("cache-control"), "no-store");
});

test("publisher rejects duplicate IDs and oversized images before publication", async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "bikespot-backgrounds-validation-"));
  t.after(() => fs.rm(root, { recursive: true }));
  const source = path.join(root, "source");
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, "same.jpg"), Buffer.from([255, 216, 255]));
  await fs.writeFile(path.join(source, "same.png"), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  await assert.rejects(publishBackgrounds(source, path.join(root, "published")), /Invalid background image entry/);
  await fs.unlink(path.join(source, "same.png"));
  await fs.writeFile(path.join(source, "same.jpg"), Buffer.alloc(5 * 1024 * 1024 + 1));
  await assert.rejects(publishBackgrounds(source, path.join(root, "published")), /at most 5 MiB/);
});
