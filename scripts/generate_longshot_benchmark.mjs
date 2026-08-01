#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const root = path.resolve(import.meta.dirname, "..");
const fixtureURL = pathToFileURL(path.join(root, "Tests/Fixtures/longshot-benchmark.html"));
const outputRoot = process.argv[2] ?? "/tmp/shotmark-longshot-benchmark";
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const defaultScenarios = ["simple", "fixed", "translucent", "repeated", "dynamic", "lazy", "bidirectional"];
const requestedScenarios = process.argv[3]?.split(",").filter(Boolean);
const scenarios = requestedScenarios?.length ? requestedScenarios : defaultScenarios;

if (!requestedScenarios?.length) {
  await fs.rm(outputRoot, { recursive: true, force: true });
}
await fs.mkdir(outputRoot, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: chromePath });

try {
  for (const scenario of scenarios) {
    const pageScenario = scenario === "bidirectional" ? "fixed" : scenario;
    const retina = scenario === "fixed";
    const viewport = retina ? { width: 900, height: 640 } : { width: 720, height: 520 };
    const scale = retina ? 2 : 1;
    const context = await browser.newContext({ viewport, deviceScaleFactor: scale });
    const page = await context.newPage();
    const url = new URL(fixtureURL.href);
    url.searchParams.set("scenario", pageScenario);
    await page.goto(url.href, { waitUntil: "load" });
    await page.emulateMedia({ reducedMotion: "no-preference" });

    const directory = path.join(outputRoot, scenario);
    await fs.rm(directory, { recursive: true, force: true });
    await fs.mkdir(directory, { recursive: true });

    // Bidirectional capture models ShotMark's 30fps stream/56pt automatic
    // scrolling cadence. Other scenarios retain larger jumps as stress tests.
    const hasFloatingOverlay = !["simple", "repeated"].includes(scenario);
    const step = hasFloatingOverlay ? 112 : 236;
    let maximumOffset = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
    let offsets;
    if (scenario === "bidirectional") {
      const middle = Math.round(maximumOffset * 0.48);
      const upward = [];
      for (let value = middle; value > 0; value -= step) upward.push(Math.max(0, value));
      if (upward.at(-1) !== 0) upward.push(0);
      const downward = [];
      for (let value = step; value < maximumOffset; value += step) downward.push(value);
      downward.push(maximumOffset);
      offsets = [...upward, ...downward];
    } else {
      offsets = [];
      let offset = 0;
      while (true) {
        offsets.push(Math.min(offset, maximumOffset));
        if (offset >= maximumOffset) break;
        offset += step;
        if (scenario === "lazy") {
          await page.evaluate(y => scrollTo(0, y), Math.min(offset, maximumOffset));
          await page.waitForTimeout(80);
          maximumOffset = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
        }
      }
      if (offsets.at(-1) !== maximumOffset) offsets.push(maximumOffset);
    }

    const frames = [];
    for (const [index, requestedOffset] of offsets.entries()) {
      await page.evaluate(y => scrollTo(0, y), requestedOffset);
      await page.waitForTimeout(scenario === "dynamic" ? 140 : 45);
      const offset = await page.evaluate(() => Math.round(scrollY));
      const file = `frame-${String(index).padStart(3, "0")}-${String(offset).padStart(6, "0")}.png`;
      await page.screenshot({ path: path.join(directory, file), animations: "allow" });
      frames.push({ file, offset });
    }

    const pageMetrics = await page.evaluate(() => {
      const rows = [...document.querySelectorAll(".row")];
      const first = rows[0];
      const floatingOverlay = document.querySelector(".moving-ad")?.getBoundingClientRect();
      const x = first ? Math.round(first.getBoundingClientRect().left + 20) : 30;
      const markers = rows.map((row, index) => {
        const color = getComputedStyle(row, "::before").backgroundColor.match(/\d+/g)?.slice(0, 3).map(Number) ?? [];
        return { index, color };
      });
      return {
        documentHeight: document.documentElement.scrollHeight,
        markerX: x,
        floatingOverlayProbeX: floatingOverlay ? Math.round(floatingOverlay.left + floatingOverlay.width / 2) : null,
        markers
      };
    });

    const manifest = {
      scenario,
      viewport,
      scale,
      documentHeight: pageMetrics.documentHeight,
      markerX: pageMetrics.markerX,
      floatingOverlayProbeX: ["fixed", "translucent", "lazy", "bidirectional"].includes(scenario)
        ? pageMetrics.floatingOverlayProbeX
        : null,
      markers: pageMetrics.markers,
      frames
    };
    await fs.writeFile(path.join(directory, "manifest.json"), JSON.stringify(manifest, null, 2));
    console.log(`${scenario}: ${frames.length} frames, ${pageMetrics.documentHeight}px document`);
    await context.close();
  }
} finally {
  await browser.close();
}
