import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const rootDir = dirname(fileURLToPath(import.meta.url));
const srcDir = join(rootDir, "src");
const outputDir = resolve(rootDir, "../../supacode/Resources/PierrePanel");

await mkdir(outputDir, { recursive: true });

await build({
  entryPoints: [join(srcDir, "panel.js")],
  bundle: true,
  minify: true,
  format: "esm",
  target: ["safari17"],
  outfile: join(outputDir, "panel.js"),
});

await copyFile(join(srcDir, "index.html"), join(outputDir, "index.html"));
await copyFile(join(srcDir, "panel.css"), join(outputDir, "panel.css"));
