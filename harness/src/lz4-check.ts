import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import lz4 from "lz4js";
import { harnessRoot, repoRoot } from "./transport.js";

// Swift compresses (fixture inputs + fresh random inputs); lz4js must reproduce every input.
const directory = mkdtempSync(join(tmpdir(), "lz4-check-"));
try {
  const output = join(directory, "swift.json");
  execFileSync(
    "swift",
    ["run", "--package-path", repoRoot, "--scratch-path", join(repoRoot, ".build/lz4-check"),
      "FluidLZ4Check", join(harnessRoot, "fixtures/lz4.json"), output],
    { stdio: ["ignore", "ignore", "inherit"] },
  );
  const frames = JSON.parse(readFileSync(output, "utf8")) as { input: string; compressed: string }[];
  for (const [i, frame] of frames.entries()) {
    const decoded = Buffer.from(lz4.decompress([...Buffer.from(frame.compressed, "base64")]));
    if (!decoded.equals(Buffer.from(frame.input, "base64")))
      throw new Error(`lz4js could not reproduce Swift frame ${i}`);
  }
  console.log(`lz4-check: ${frames.length} Swift frames decoded by lz4js`);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
