#!/usr/bin/env node
// Writes docs/demo.gif: the lines below typed into a text field, each word changed the way
// `autocorrect --fix` changes it, rendered in headless WebKit (no window) and put together by ffmpeg.
// Needs `swift build -c release`, ffmpeg, and Playwright (npm i playwright).
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// "⌫" right after a word: the fix is taken back, as ⌫ does.
const LINES = [
  "ca va tres bien, cest peutetre la meilleure idee",
  "i dont think teh plan is ready",
  "attends tema ⌫la video, cest vraiemtn cool",
];

const engine = join(here, "../.build/release/autocorrect");
const typed = LINES.map((l) => l.replaceAll("⌫", ""));
const fixed = execFileSync(engine, ["--fix"], { input: typed.join("\n") + "\n" }).toString().trimEnd().split("\n");

const { webkit } = createRequire(import.meta.url)("playwright");

const page_ = `<html><head><style>
  body { margin: 0; width: 960px; height: 290px; display: flex; align-items: center; justify-content: center;
         background: linear-gradient(135deg, #d9e4f2, #f3e9e1); font-family: -apple-system, sans-serif; }
  .win { position: relative; width: 860px; height: 236px; background: #fff; border-radius: 12px;
         box-shadow: 0 18px 50px rgba(0,0,0,.18), 0 0 0 1px rgba(0,0,0,.08); overflow: hidden; }
  .bar { height: 38px; background: #f6f6f6; border-bottom: 1px solid #e5e5e5; display: flex; align-items: center; padding-left: 14px; gap: 8px; }
  .bar i { width: 12px; height: 12px; border-radius: 50%; }
  .text { padding: 22px 28px; font-size: 25px; line-height: 1.6; color: #1d1d1f; white-space: pre; }
  .w { border-radius: 5px; }
  .caret { display: inline-block; width: 2px; height: 30px; background: #007aff; vertical-align: -6px; }
  .key { position: absolute; right: 18px; bottom: 16px; padding: 6px 14px; border-radius: 8px; font-size: 17px;
         color: #333; background: #f2f2f4; border: 1px solid #d0d0d6; box-shadow: 0 2px 0 #d0d0d6; }
</style></head><body><div class="win"><div class="bar"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>
<div class="text" id="text"></div><div class="key" id="key"></div></div></body></html>`;

// A frame: the lines as words, the glow left on each changed one, the key last pressed.
const frames = [];
const lines = [];
let key = "";
let keyLeft = 0;
const shot = (ms, caret = true) => {
  frames.push({ ms, caret, key: keyLeft > 0 ? key : "", lines: structuredClone(lines) });
  for (const l of lines) for (const w of l) w.glow = Math.max(0, w.glow - 0.12);
  keyLeft--;
};
const press = (label) => { key = label; keyLeft = 6; };

LINES.forEach((line, n) => {
  const words = fixed[n].split(" ");
  const words_ = typed[n].split(" ");
  if (words.length !== words_.length) throw new Error(`line ${n}: ${typed[n]} -> ${fixed[n]}`);
  const cur = [{ text: "", glow: 0, undo: false }];
  lines.push(cur);
  let i = 0;
  for (let c = 0; c < line.length; c++) {
    const ch = line[c];
    const w = cur[cur.length - 1];
    if (ch === " ") {
      press("space");
      if (words[i] !== words_[i]) {
        w.text = words[i];
        w.glow = 1;
        shot(line[c + 1] === "⌫" ? 900 : 380);
      }
      i++;
      w.text += " ";
      cur.push({ text: "", glow: 0, undo: false });
      if (line[c + 1] !== "⌫" && words[i - 1] === words_[i - 1]) shot(75);
    } else if (ch === "⌫") {
      const prev = cur[cur.length - 2];
      prev.text = words_[i - 1] + " ";
      prev.glow = 1;
      prev.undo = true;
      press("⌫ kept as typed");
      shot(1100);
    } else {
      w.text += ch;
      shot(75);
    }
  }
  if (n === LINES.length - 1) return;
  press("return");
  const w = cur[cur.length - 1];
  if (words[i] !== words_[i]) { w.text = words[i]; w.glow = 1; }
  shot(450);
});
for (let k = 0; k < 8; k++) shot(400, k % 2 === 0);

const out = mkdtempSync(join(tmpdir(), "demo-"));
const browser = await webkit.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 960, height: 290 }, deviceScaleFactor: 2 });
await page.setContent(page_);
let list = "";
for (const [n, f] of frames.entries()) {
  await page.evaluate((f) => {
    const glow = (w) => w.glow <= 0 ? "" : `background: rgba(${w.undo ? "255,149,0" : "52,199,89"},${0.35 * w.glow})`;
    const html = (w) => `<span class="w" style="${glow(w)}">${w.text.replace(/ $/, "")}</span>${w.text.endsWith(" ") ? " " : ""}`;
    document.getElementById("text").innerHTML = f.lines.map((l, i) => l.map(html).join("") +
      (i === f.lines.length - 1 && f.caret ? '<span class="caret"></span>' : "")).join("\n");
    const key = document.getElementById("key");
    key.textContent = f.key;
    key.style.visibility = f.key ? "visible" : "hidden";
  }, f);
  const png = join(out, `${String(n).padStart(4, "0")}.png`);
  await page.screenshot({ path: png });
  list += `file '${png}'\nduration ${f.ms / 1000}\n`;
}
await browser.close();
writeFileSync(join(out, "list.txt"), list + `file '${join(out, String(frames.length - 1).padStart(4, "0") + ".png")}'\n`);
execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", join(out, "list.txt"), "-fps_mode", "vfr",
  "-vf", "scale=1440:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
  "-loop", "0", join(here, "demo.gif")]);
console.log(`${frames.length} frames -> ${join(here, "demo.gif")}`);
