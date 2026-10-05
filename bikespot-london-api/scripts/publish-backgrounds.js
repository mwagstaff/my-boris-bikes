const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { validateCatalog, defaultDirectory, MAX_IMAGE_BYTES, ID_PATTERN } = require("../background-images");

// The source directory is the complete desired collection. Its filenames are stable image IDs.
async function publishBackgrounds(source, destination = defaultDirectory()) {
  source = path.resolve(source);
  destination = path.resolve(destination);
  if (source === destination) throw new Error("Source and published directories must be different");
  const files = (await fs.readdir(source, { withFileTypes: true }))
    .filter(file => file.isFile() && /\.(jpe?g|png)$/i.test(file.name))
    .sort((a, b) => a.name.localeCompare(b.name, "en"));
  if (files.length > 100) throw new Error("Maximum 100 backgrounds");
  const prepared = [];
  for (const file of files) {
    const extension = path.extname(file.name).toLowerCase();
    const id = path.basename(file.name, path.extname(file.name));
    if (!ID_PATTERN.test(id)) throw new Error(`Invalid image ID: ${id}`);
    const sourceFile = path.join(source, file.name);
    const size = (await fs.stat(sourceFile)).size;
    if (size < 1 || size > MAX_IMAGE_BYTES) throw new Error(`Image must be at most 5 MiB: ${file.name}`);
    const bytes = await fs.readFile(sourceFile);
    const png = extension === ".png";
    const validHeader = png
      ? bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
      : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    if (!validHeader) throw new Error(`Expected JPEG or PNG data: ${file.name}`);
    const sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
    prepared.push({ bytes, entry: { id, file: `${id}-${sha256}.${png ? "png" : "jpg"}`, sha256, byteCount: bytes.length } });
  }
  const catalog = validateCatalog({ schemaVersion: 1, images: prepared.map(image => image.entry) });
  await fs.mkdir(destination, { recursive: true });
  for (const image of prepared) {
    await atomicWrite(path.join(destination, image.entry.file), image.bytes);
  }
  // Publish last, so a reader never sees entries before their files are available.
  await atomicWrite(path.join(destination, "catalog.json"), JSON.stringify(catalog, null, 2) + "\n");
  return catalog;
}

async function atomicWrite(file, data) {
  const temporary = `${file}.${crypto.randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, data);
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

if (require.main === module) {
  const [source, destination] = process.argv.slice(2);
  if (!source) {
    console.error("Usage: node scripts/publish-backgrounds.js SOURCE_DIRECTORY [PUBLISHED_DIRECTORY]");
    process.exitCode = 1;
  } else {
    publishBackgrounds(source, destination).then(catalog => {
      console.log(`Published ${catalog.images.length} backgrounds to ${path.resolve(destination || defaultDirectory())}`);
    }).catch(error => { console.error(error.message); process.exitCode = 1; });
  }
}

module.exports = { publishBackgrounds };
