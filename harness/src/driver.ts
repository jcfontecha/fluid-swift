import { mkdir, writeFile } from "node:fs/promises";
import { z } from "zod";
import { Peer, harnessRoot, type TraceEntry } from "./transport.js";
import { Session } from "./session.js";
import { Random } from "./random.js";
const args = process.argv.slice(2);
const option = (name: string, fallback: string): string => {
  const i = args.indexOf(name);
  return i < 0 ? fallback : (args[i + 1] ?? fallback);
};
const kinds = z
  .array(z.enum(["ts", "swift"]))
  .min(1)
  .parse(option("--peers", "ts,swift").split(","));
const range = /^(\d+)(?:\.\.(\d+))?$/.exec(option("--seeds", "0..499"));
if (!range) throw new Error("Expected --seeds N or N..M");
const start = Number(range[1]),
  end = Number(range[2] ?? range[1]);
if (
  !Number.isSafeInteger(start) ||
  !Number.isSafeInteger(end) ||
  start > end ||
  end > 0xffffffff
)
  throw new Error("Invalid seed range");
let failures = 0;
for (let seed = start; seed <= end; seed++) {
  const trace: TraceEntry[] = [];
  const peers: Peer[] = [];
  try {
    for (const [i, kind] of kinds.entries())
      peers.push(new Peer(kind, i, trace));
    await new Session(peers, new Random(seed)).run();
  } catch (error) {
    failures++;
    await mkdir(`${harnessRoot}traces`, { recursive: true });
    const reason = error instanceof Error ? error.message : String(error);
    await writeFile(
      `${harnessRoot}traces/${seed}.jsonl`,
      [
        JSON.stringify({ version: 1, seed, peers: kinds, failure: reason }),
        ...trace.map((entry) => JSON.stringify(entry)),
      ].join("\n") + "\n",
    );
    console.error(
      `seed ${seed} FAIL: ${reason.replaceAll("\n", " ")} (traces/${seed}.jsonl)`,
    );
    // Configuration and startup failures won't change on the next seed.
    if (trace.length === 0 || /binary missing|exited|timed out/.test(reason))
      break;
  } finally {
    await Promise.all(peers.map((peer) => peer.close()));
  }
  if ((seed - start + 1) % 50 === 0)
    console.log(`${seed - start + 1} seeds exercised`);
}
console.log(
  `${failures ? "FAIL" : "PASS"} seeds ${start}..${end}; ${failures} failures`,
);
if (failures) process.exitCode = 1;
