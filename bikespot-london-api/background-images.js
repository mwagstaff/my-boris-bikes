const fs = require("node:fs/promises");
const path = require("node:path");

const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const MAX_CATALOG_BYTES = 128 * 1024;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,80}$/;
const FILE_PATTERN = /^[A-Za-z0-9_-]{1,80}-[a-f0-9]{64}\.(jpg|png)$/;
const defaultDirectory = () => path.resolve(process.env.BACKGROUND_IMAGES_DIR || path.join(__dirname, "data/backgrounds"));

function validateCatalog(catalog) {
  if (catalog?.schemaVersion !== 1 || !Array.isArray(catalog.images) || catalog.images.length > 100) {
    throw new Error("Invalid background catalogue");
  }
  const ids = new Set();
  for (const image of catalog.images) {
    if (!ID_PATTERN.test(image.id) || ids.has(image.id) ||
        !/^[a-f0-9]{64}$/.test(image.sha256) || !FILE_PATTERN.test(image.file) ||
        ![`${image.id}-${image.sha256}.jpg`, `${image.id}-${image.sha256}.png`].includes(image.file) ||
        !Number.isInteger(image.byteCount) || image.byteCount < 1 || image.byteCount > MAX_IMAGE_BYTES) {
      throw new Error("Invalid background image entry");
    }
    ids.add(image.id);
  }
  return catalog;
}

function registerBackgroundRoutes(app, { directory = defaultDirectory() } = {}) {
  directory = path.resolve(directory);

  app.get("/backgrounds", async (_req, res) => {
    try {
      const manifest = path.join(directory, "catalog.json");
      if ((await fs.stat(manifest)).size > MAX_CATALOG_BYTES) throw new Error("Catalogue too large");
      const catalog = validateCatalog(JSON.parse(await fs.readFile(manifest, "utf8")));
      await Promise.all(catalog.images.map(async image => {
        const stat = await fs.stat(path.join(directory, image.file));
        if (!stat.isFile() || stat.size !== image.byteCount) throw new Error("Image unavailable");
      }));
      res.set("Cache-Control", "public, max-age=300").json(catalog);
    } catch {
      res.set("Cache-Control", "no-store").status(503).json({ error: "Background catalogue unavailable" });
    }
  });

  app.get("/backgrounds/images/:file", (req, res) => {
    if (!FILE_PATTERN.test(req.params.file)) return res.status(404).end();
    res.set("X-Content-Type-Options", "nosniff");
    res.sendFile(req.params.file, {
      root: directory, dotfiles: "deny", maxAge: "1y", immutable: true,
    }, error => {
      if (error && !res.headersSent) res.status(error.statusCode || 500).end();
    });
  });
}

module.exports = { registerBackgroundRoutes, validateCatalog, defaultDirectory, MAX_IMAGE_BYTES, ID_PATTERN };
