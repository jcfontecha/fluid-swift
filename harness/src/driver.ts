import { mkdir, writeFile } from "node:fs/promises";
import { z } from "zod";
import { Peer, harnessRoot, type TraceEntry } from "./transport.js";
import { Session } from "./session.js";
import { names, type DDSName } from "./dds.js";
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
const selected = option("--dds", "counter");
const ddss =
  selected === "all"
    ? names
    : selected.split(",").map((n) => {
        if (!names.includes(n as DDSName)) throw Error(`Unknown DDS ${n}`);
        return n as DDSName;
      });
let failures = 0;
for (const dds of ddss) {
  const peers = kinds.map((kind, i) => new Peer(kind, i, []));
  let ddsFailures = 0;
  try {
    for (let seed = start; seed <= end; seed++) {
      const trace: TraceEntry[] = [];
      for (const peer of peers) {
        await peer.call({ method: "reset", params: {} });
        peer.startTrace(trace);
      }
      try {
        await new Session(peers, new Random(seed), dds).run();
      } catch (error) {
        failures++;
        ddsFailures++;
        const reason = error instanceof Error ? error.message : String(error);
        const file = `${dds}-${kinds.join("-")}-${seed}.jsonl`;
        await mkdir(`${harnessRoot}traces`, { recursive: true });
        await writeFile(
          `${harnessRoot}traces/${file}`,
          [
            JSON.stringify({
              version: 1,
              dds,
              seed,
              peers: kinds,
              failure: reason,
            }),
            ...trace.map((entry) => JSON.stringify(entry)),
          ].join("\n") + "\n",
        );
        console.error(
          `${dds} seed ${seed} FAIL: ${reason.slice(0, 300).replaceAll("\n", " ")} (traces/${file})`,
        );
        if (
          trace.length === 0 ||
          /binary missing|exited|timed out/.test(reason)
        )
          break;
      }
      if ((seed - start + 1) % 50 === 0)
        console.log(`${dds}: ${seed - start + 1} seeds exercised`);
    }
  } finally {
    await Promise.all(peers.map((peer) => peer.close()));
  }
  console.log(
    `${dds}: ${ddsFailures ? "FAIL" : "PASS"} seeds ${start}..${end}; ${ddsFailures} failures`,
  );
}
if (failures) process.exitCode = 1;
