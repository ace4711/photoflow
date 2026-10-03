// Minimal byggkedja: esbuild buntar src/editor.ts till dist/editor.js och
// kopierar index.html + styles.css. `node build.mjs --serve` bygger om och
// serverar dist/ på http://localhost:8080 (esbuild --servedir).
import { build, context } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

const serve = process.argv.includes("--serve");
rmSync("dist", { recursive: true, force: true });
mkdirSync("dist", { recursive: true });
cpSync("index.html", "dist/index.html");
cpSync("src/styles.css", "dist/styles.css");

const options = {
  entryPoints: ["src/editor.ts"],
  bundle: true,
  format: "esm",
  target: "es2022",
  outfile: "dist/editor.js",
  sourcemap: true,
  logLevel: "info",
};

if (serve) {
  const ctx = await context(options);
  await ctx.watch();
  const { port } = await ctx.serve({ servedir: "dist", port: 8080 });
  console.log(`Öppna http://localhost:${port}/`);
} else {
  await build({ ...options, minify: true });
}
