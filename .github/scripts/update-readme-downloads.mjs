import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

const version = requiredEnv("RELEASE_VERSION");
const tag = process.env.RELEASE_TAG || `v${version}`;
const repository = requiredEnv("GITHUB_REPOSITORY");
const testFlightUrl =
  process.env.TESTFLIGHT_URL || "https://testflight.apple.com/join/tyHPrUny";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const readmePath = resolve(scriptDir, "../../README.md");
const githubReleaseBase = `https://github.com/${repository}/releases`;
const macAsset = `RemoteDesktopHost-macOS-${version}.zip`;
const windowsAsset = `RemoteDesktopHost-Setup-${version}.exe`;

const replacement = [
  "<!-- download-links:start -->",
  `Latest host release: [${tag}](${githubReleaseBase}/tag/${tag})`,
  "",
  `- iPhone and iPad beta: [Join TestFlight](${testFlightUrl})`,
  `- macOS host: [${macAsset}](${githubReleaseBase}/download/${tag}/${macAsset})`,
  `- Windows host: [${windowsAsset}](${githubReleaseBase}/download/${tag}/${windowsAsset})`,
  "<!-- download-links:end -->",
].join("\n");

const readme = readFileSync(readmePath, "utf8");
const markerPattern =
  /<!-- download-links:start -->[\s\S]*?<!-- download-links:end -->/;

if (!markerPattern.test(readme)) {
  throw new Error("README.md is missing the download-links marker block");
}

writeFileSync(readmePath, `${readme.replace(markerPattern, replacement).trimEnd()}\n`);
