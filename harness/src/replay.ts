import { readFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import {
  requestSchema,
  rpcResponseSchema,
  outboundResult,
} from "./protocol.js";
import { Peer, type TraceEntry } from "./transport.js";
const path = process.argv[2];
if (!path) throw new Error("Usage: npm run replay -- traces/<seed>.jsonl");
const lines = (await readFile(path, "utf8")).trim().split("\n");
const header = z
  .object({
    version: z.literal(1),
    peers: z.array(z.enum(["ts", "swift"])),
    failure: z.string(),
  })
  .parse(JSON.parse(lines.shift() ?? ""));
const entrySchema = z.object({
  peer: z.number().int(),
  direction: z.enum(["request", "response"]),
  payload: z.unknown(),
});
const peers: Peer[] = [];
const trace: TraceEntry[] = [];
let count = 0;
let baselineState: unknown;
let previousCall:
  { peer: number; request: string; result: unknown } | undefined;
let reproduced = false;
const clients = new Map<
  string,
  { cursor: number; csn: number; wireId: string }
>();
try {
  for (const [i, kind] of header.peers.entries())
    peers.push(new Peer(kind, i, trace));
  for (let i = 0; i < lines.length; i += 2) {
    const request = entrySchema.parse(JSON.parse(lines[i] ?? ""));
    const expectedLine = lines[i + 1];
    if (!expectedLine) throw new Error("Trace ends with unanswered request");
    const expected = entrySchema.parse(JSON.parse(expectedLine));
    if (
      request.direction !== "request" ||
      expected.direction !== "response" ||
      request.peer !== expected.peer
    )
      throw new Error("Invalid trace ordering");
    const peer = peers[request.peer];
    if (!peer) throw new Error("Invalid trace peer");
    const call = requestSchema.parse(request.payload);
    let peerError: unknown;
    try {
      await peer.call(call);
    } catch (error) {
      peerError = error;
    }
    const actual = trace.at(-1);
    if (actual?.direction !== "response")
      throw peerError ?? new Error("Missing response");
    if (
      !isDeepStrictEqual(actual.payload, expected.payload) ||
      JSON.stringify(actual.payload) !== JSON.stringify(expected.payload)
    )
      throw new Error(`Replay response changed at request ${count + 1}`);
    count++;
    const response = rpcResponseSchema.parse(actual.payload);
    if (peerError) {
      reproduced = true;
      break;
    }
    const fingerprint = JSON.stringify(call);
    if (
      previousCall?.peer !== request.peer &&
      previousCall?.request === fingerprint &&
      JSON.stringify(previousCall.result) !== JSON.stringify(response.result)
    ) {
      reproduced = true;
      break;
    }
    previousCall = {
      peer: request.peer,
      request: fingerprint,
      result: response.result,
    };
    const key =
      "clientId" in call.params
        ? `${request.peer}:${call.params.clientId}`
        : "";
    if (call.method === "createClient")
      clients.set(key, {
        cursor: call.params.sequenceNumber,
        csn: 0,
        wireId: call.params.clientId,
      });
    if (call.method === "reconnect") {
      const c = clients.get(key);
      if (!c) throw Error("unknown reconnect client");
      c.wireId = call.params.newClientId;
      c.csn = 0;
    }
    if (
      call.method === "edit" ||
      call.method === "process" ||
      call.method === "reconnect" ||
      call.method === "flush" ||
      call.method === "rollback" ||
      call.method === "stash" ||
      call.method === "membership" ||
      call.method === "disconnect"
    ) {
      const client = clients.get(key);
      if (!client) throw new Error("Trace references unknown client");
      if (call.method === "process")
        client.cursor = call.params.message.sequenceNumber;
      try {
        for (const op of (call.method === "reconnect"
          ? z
              .object({
                outbound: outboundResult.shape.outbound,
                clientId: z.string(),
              })
              .parse(response.result)
          : outboundResult.parse(response.result)
        ).outbound) {
          if (
            op.clientId !== client.wireId ||
            op.referenceSequenceNumber !== client.cursor ||
            op.clientSequenceNumber <= client.csn
          )
            throw new Error("Outbound protocol violation");
          client.csn = op.clientSequenceNumber;
        }
      } catch {
        reproduced = true;
        break;
      }
    }
    if (call.method === "state") {
      if (
        baselineState !== undefined &&
        !isDeepStrictEqual(response.result, baselineState)
      ) {
        reproduced = true;
        break;
      }
      baselineState = response.result;
    } else if (
      call.method === "edit" ||
      call.method === "process" ||
      call.method === "reconnect" ||
      call.method === "disconnect" ||
      call.method === "membership" ||
      call.method === "flush" ||
      call.method === "rollback" ||
      call.method === "stash" ||
      (call.method === "createClient" &&
        !call.params.clientId.startsWith("cross-load-"))
    ) {
      baselineState = undefined;
    }
  }
  if (!reproduced)
    throw new Error(
      `Responses replayed exactly (${count}), but original failure was not reproduced: ${header.failure}`,
    );
  console.log(`REPRODUCED after ${count} requests: ${header.failure}`);
  process.exitCode = 1;
} finally {
  await Promise.all(peers.map((peer) => peer.close()));
}
