import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { Peer, type TraceEntry } from "./transport.js";
import { outboundResult, type Request, type Edit, type Message } from "./protocol.js";

const trace: TraceEntry[] = [];
const peers = [new Peer("ts", 0, trace), new Peer("swift", 1, trace)];
const clientId = "A";
let sequenceNumber = 0;
async function both(request: Request): Promise<unknown> {
  const results = [];
  for (const peer of peers) results.push(await peer.call(request));
  assert.deepEqual(results[1], results[0], `${request.method}: ${JSON.stringify(request.params)}`);
  return results[0];
}
async function edit(edit: Edit) { await both({ method: "edit", params: { clientId, edit } }); }
async function checkpoint() {
  for (const method of ["state", "queries", "events", "summarize"] as const) {
    await both({ method, params: { clientId } });
  }
}
async function flushAndAck() {
  const result = outboundResult.parse(await both({ method: "flush", params: { clientId } }));
  for (const message of result.outbound) {
    await both({ method: "process", params: { clientId, message: {
      ...message, sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, type: "op",
    } } });
  }
}
try {
  await both({ method: "createClient", params: { clientId, channelId: "text",
    ddsType: "https://graph.microsoft.com/types/mergeTree", sequenceNumber: 0, summary: null, flushMode: "turnBased" } });
  await edit({ kind: "insertText", position: 0, text: "abcdef" });
  await flushAndAck();
  await checkpoint();
  await edit({ kind: "addInterval", collection: "c", id: "one", start: 1, end: 3, props: { color: "red" } });
  await edit({ kind: "addInterval", collection: "c", id: "two", start: 2, end: 4 });
  await edit({ kind: "changeInterval", collection: "c", id: "one", start: 0, end: 4, props: { color: "blue" } });
  await edit({ kind: "deleteInterval", collection: "c", id: "two" });
  await checkpoint();
  await both({ method: "rollback", params: { clientId } });
  await checkpoint();
  await both({ method: "stash", params: { clientId, contents: { key: "c", type: "act", value: {
    opName: "add", value: { end: 3, intervalType: 2, sequenceNumber, start: 1, stickiness: 2,
      startSide: 0, endSide: 0, properties: { color: "green", intervalId: "stashed", referenceRangeLabels: ["c"] } },
  } } } });
  await checkpoint();
  await flushAndAck();
  await checkpoint();
  await both({ method: "disconnect", params: { clientId } });
  await edit({ kind: "insertText", position: 0, text: "local" });
  await edit({ kind: "changeInterval", collection: "c", id: "stashed", start: { pos: 2, side: 1 }, end: { pos: 4, side: 0 } });
  const remote: Message = { clientId: "remote", clientSequenceNumber: 1,
    referenceSequenceNumber: sequenceNumber, contents: { pos1: 0, seg: "R", type: 0 },
    sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, type: "op" };
  await both({ method: "process", params: { clientId, message: remote } });
  await both({ method: "reconnect", params: { clientId, newClientId: "A-again" } });
  await both({ method: "disconnect", params: { clientId } });
  await both({ method: "reconnect", params: { clientId, newClientId: "A-twice" } });
  await checkpoint();
  await flushAndAck();
  await checkpoint();
  console.log("SharedString interval batch rollback, stash, and repeated reconnect PASS");
} catch (error) {
  await writeFile("artifacts/f2/f2-lifecycle-trace.jsonl", trace.map((entry) => JSON.stringify(entry)).join("\n"));
  throw error;
} finally {
  for (const peer of peers) await peer.close();
}
