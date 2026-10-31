#!/usr/bin/env node
// release-manifest.json is the one list of what an on-prem release contains.
// The chart and every "this guide describes" header must agree with it. A line
// such as "callme 1.11.0 and later" is history, not a claim, and is not checked.
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const read = (file) => readFileSync(new URL(file, root), "utf8");
const manifest = JSON.parse(read("release-manifest.json"));
const failures = [];
const expect = (file, what, written, wanted) => {
  if (written !== wanted) failures.push(`${file}: ${what} is ${written ?? "missing"}, the manifest has ${wanted}`);
};

const chart = read("helm/callman/Chart.yaml");
expect("helm/callman/Chart.yaml", "version", chart.match(/^version:\s*"?([^"\s]+)/m)?.[1], manifest.chart);
expect("helm/callman/Chart.yaml", "appVersion", chart.match(/^appVersion:\s*"?([^"\s]+)/m)?.[1], manifest.onprem);

const CLAIMS = [
  ["on-prem", "onprem", /Callman on-prem\s+(\d+\.\d+\.\d+)/],
  ["chart", "chart", /Helm chart\s+(\d+\.\d+\.\d+)/],
  ["desktop", "desktop", /desktop\s+\*{0,2}(\d+\.\d+\.\d+)/],
  ["CLI", "cli", /`callme-cli`\)?\s+(\d+\.\d+\.\d+)/],
  ["MCP", "mcp", /`callman-mcp`\)?\s+(\d+\.\d+\.\d+)/],
];
const HEADERS = [
  ["README.md", /This documentation describes[\s\S]*?\n\n/, ["onprem", "chart", "desktop", "cli", "mcp"]],
  ["docs/INSTALL.md", /This guide describes[\s\S]*?\n\n/, ["onprem", "desktop", "cli", "mcp"]],
  ["docs/HELM-INSTALL.md", /This guide describes[\s\S]*?\n\n/, ["onprem", "chart", "desktop", "cli", "mcp"]],
  ["docs/POC-EVALUATION-GUIDE.md", /Versions this guide describes[\s\S]*?\n\n/, ["onprem", "desktop", "cli", "mcp"]],
  ["docs/THIRD-PARTY.md", /It describes desktop[^\n]*\n/, ["desktop"]],
];
for (const [file, pattern, required] of HEADERS) {
  const header = read(file).match(pattern)?.[0];
  if (!header) {
    failures.push(`${file}: the versions header was not found`);
    continue;
  }
  for (const [what, key, claim] of CLAIMS) {
    if (required.includes(key)) expect(file, what, header.match(claim)?.[1], manifest[key]);
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  process.exit(1);
}
console.log(`ok   docs and chart match ${JSON.stringify(manifest)}`);
