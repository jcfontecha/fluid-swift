/** Matrix rollback/stash cases from matrix.rollback.spec.ts and matrix.applyStashedOp.spec.ts. */
import { isDeepStrictEqual } from "node:util";
import { Peer } from "./transport.js";
import { outboundResult, type Request, type Edit, type Outbound, summarySchema } from "./protocol.js";
import { z } from "zod";
import { factories } from "./dds.js";
const ts = new Peer("ts", 0, []);
const swift = new Peer("swift", 1, []);
const peers = [ts, swift];
async function both(request: Request): Promise<unknown> {
  const a = await ts.call(request);
  const b = await swift.call(request);
  if (ts.resultText !== swift.resultText) throw new Error(`${request.method}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
  return a;
}
let sequence = 0;
async function deliver(outbound: readonly Outbound[]) {
  for (const op of outbound) {
    const message = { ...op, sequenceNumber: ++sequence, minimumSequenceNumber: 0, type: "op" as const };
    for (const clientId of ["writer", "writer2", "summarizer"]) await both({ method: "process", params: { clientId, message } });
  }
}
async function edit(edit: Edit) { await both({ method: "edit", params: { clientId: "writer", edit } }); }
async function flush() { await deliver(outboundResult.parse(await both({ method: "flush", params: { clientId: "writer" } })).outbound); }
try {
  for (const clientId of ["writer", "writer2", "summarizer"]) await both({ method: "createClient", params: { clientId, ddsType: factories.matrix.type, channelId: "matrix", sequenceNumber: 0, summary: null, flushMode: "turnBased" } });
  await edit({ kind: "insertRows", start: 0, count: 3 });
  await edit({ kind: "insertCols", start: 0, count: 3 });
  await flush();
  await edit({ kind: "setCell", row: 1, col: 1, value: 42 });
  await flush();
  for (const operation of [
    { kind: "setCell", row: 1, col: 1, value: 99 },
    { kind: "insertRows", start: 1, count: 2 },
    { kind: "removeRows", start: 1, count: 1 },
    { kind: "insertCols", start: 1, count: 2 },
    { kind: "removeCols", start: 1, count: 1 },
  ] satisfies Edit[]) {
    const before = await both({ method: "state", params: { clientId: "writer" } });
    await edit(operation);
    await both({ method: "rollback", params: { clientId: "writer" } });
    const after = await both({ method: "state", params: { clientId: "writer" } });
    if (!isDeepStrictEqual(before, after)) throw new Error(`Rollback failed: ${operation.kind}`);
    await both({ method: "events", params: { clientId: "writer" } });
  }
  // LWW concurrent local writes: the later sequenced write wins, including optimistic state.
  await edit({ kind: "setCell", row: 1, col: 1, value: 91 });
  await both({ method: "edit", params: { clientId: "writer2", edit: { kind: "setCell", row: 1, col: 1, value: 92 } } });
  const first = outboundResult.parse(await both({ method: "flush", params: { clientId: "writer" } })).outbound;
  const second = outboundResult.parse(await both({ method: "flush", params: { clientId: "writer2" } })).outbound;
  await deliver([...first, ...second]);
  for (const clientId of ["writer", "writer2", "summarizer"]) await both({ method: "state", params: { clientId } });
  await both({ method: "stash", params: { clientId: "writer", contents: { type: 2, row: 0, col: 0, value: 17, fwwMode: false } } });
  await flush();
  await both({ method: "stash", params: { clientId: "writer", contents: { pos1: 0, seg: [2, -2147483648], type: 0, target: "rows" } } });
  await flush();
  await both({ method: "stash", params: { clientId: "writer", contents: {
    ops: [{ pos1: 0, seg: [1, -2147483648], type: 0 }, { pos1: 1, seg: [1, -2147483648], type: 0 }], type: 3, target: "cols",
  } } });
  await flush();
  await both({ method: "stash", params: { clientId: "writer", contents: { type: 2, row: 0, col: 0, value: 23, fwwMode: true } } });
  await flush();
  // FWW concurrent writes: the first sequenced write overwrites a pending competitor and emits conflict.
  await edit({ kind: "setCell", row: 0, col: 0, value: 31 });
  await both({ method: "edit", params: { clientId: "writer2", edit: { kind: "setCell", row: 0, col: 0, value: 32 } } });
  const fwwFirst = outboundResult.parse(await both({ method: "flush", params: { clientId: "writer" } })).outbound;
  const fwwSecond = outboundResult.parse(await both({ method: "flush", params: { clientId: "writer2" } })).outbound;
  await deliver([...fwwFirst, ...fwwSecond]);
  for (const clientId of ["writer", "writer2", "summarizer"]) {
    await both({ method: "state", params: { clientId } });
    await both({ method: "events", params: { clientId } });
    summarySchema.parse(z.object({ summary: summarySchema }).parse(await both({ method: "summarize", params: { clientId } })).summary);
  }
  console.log("matrix rollback/stash/LWW/FWW: PASS");
} finally { await Promise.all(peers.map((peer) => peer.close())); }
