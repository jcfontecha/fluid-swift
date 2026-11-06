import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import lz4 from "lz4js";
import { Random } from "./random.js";

// Deterministic: regenerating must reproduce the committed fixture byte for byte.
const random = new Random(0x1a4b10c5);
const randomBytes = (length: number): Buffer =>
  Buffer.from(Array.from({ length }, () => random.int(256)));

const opBatch = (count: number): Buffer =>
  Buffer.from(
    JSON.stringify({
      batch: true,
      ops: Array.from({ length: count }, (_, i) => ({
        type: "component",
        sequenceNumber: i + 1,
        contents: { value: `op-${random.int(1000)}`, repeat: "x".repeat(90) },
      })),
    }),
  );

const cases: [string, Buffer][] = [
  ["empty", Buffer.alloc(0)],
  ["one-byte", Buffer.from([0x7f])],
  ["repetitive", Buffer.from("fluid-op-batch/".repeat(5000))],
  ["random-incompressible", randomBytes(4096)],
  ["json-op-batch", opBatch(80)],
  // lz4js blocks are 4 MiB; a compressible input this size spans two blocks with a small frame.
  ["larger-than-block", opBatch(40_000)],
];

// Inputs over 64 KiB are stored by length + SHA-256 to keep the fixture small.
const inlineLimit = 64 * 1024;
writeFileSync(
  new URL("../fixtures/lz4.json", import.meta.url),
  JSON.stringify(
    cases.map(([name, input]) => ({
      name,
      ...(input.length <= inlineLimit ? { input: input.toString("base64") } : {}),
      inputLength: input.length,
      inputSHA256: createHash("sha256").update(input).digest("hex"),
      compressed: Buffer.from(lz4.compress([...input])).toString("base64"),
    })),
    null,
    1,
  ) + "\n",
);
