import { readdir, readFile, stat } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const sourceDirectory = resolve(root, "src");
const sourceFiles = (await readdir(sourceDirectory))
  .filter((name) => name.endsWith(".js"))
  .map((name) => resolve(sourceDirectory, name));
const files = [
  resolve(root, "index.html"),
  resolve(root, "styles.css"),
  ...sourceFiles,
];

const sizes = await Promise.all(files.map(async (file) => (await stat(file)).size));
const total = sizes.reduce((sum, size) => sum + size, 0);
const limit = 150 * 1_024;

if (total > limit) {
  throw new Error(`Production WebUI is ${total} bytes; the limit is ${limit} bytes.`);
}

const contents = await Promise.all(files.map((file) => readFile(file, "utf8")));
const externalRuntime = /<(?:script|link)\b[^>]*(?:src|href)=["']https?:|@import\s+(?:url\()?["']?https?:/i;
if (contents.some((content) => externalRuntime.test(content))) {
  throw new Error("Production WebUI contains an external runtime request.");
}

process.stdout.write(`Production WebUI: ${total} / ${limit} bytes\n`);
