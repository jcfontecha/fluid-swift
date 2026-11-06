import assert from "node:assert/strict";
import { Peer } from "./transport.js";
import { outboundResult } from "./protocol.js";
const peers = [new Peer("ts", 0, []), new Peer("ts", 1, [])];
try {
  const [a, b] = peers;
  assert(a && b);
  for (const [peer, id] of [
    [a, "A"],
    [b, "B"],
  ] as const)
    await peer.call({
      method: "createClient",
      params: {
        clientId: id,
        ddsType: "https://graph.microsoft.com/types/directory",
        channelId: "directory",
        sequenceNumber: 0,
        summary: null,
        members: ["A", "B"],
      },
    });
  const edits = outboundResult.parse(
    await a.call({
      method: "edit",
      params: {
        clientId: "A",
        edit: { kind: "createSubDirectory", path: "/", name: "one" },
      },
    }),
  );
  const op = edits.outbound[0];
  assert(op);
  const message = {
    ...op,
    sequenceNumber: 1,
    minimumSequenceNumber: 0,
    type: "op" as const,
  };
  for (const [peer, id] of [
    [a, "A"],
    [b, "B"],
  ] as const)
    await peer.call({ method: "process", params: { clientId: id, message } });
  assert.deepEqual(
    await a.call({ method: "summarize", params: { clientId: "A" } }),
    await b.call({ method: "summarize", params: { clientId: "B" } }),
  );
  const reuse = outboundResult.parse(
    await b.call({
      method: "edit",
      params: {
        clientId: "B",
        edit: { kind: "createSubDirectory", path: "/", name: "one" },
      },
    }),
  );
  assert.equal(reuse.outbound.length, 0);
  assert.deepEqual(
    await a.call({ method: "state", params: { clientId: "A" } }),
    await b.call({ method: "state", params: { clientId: "B" } }),
  );
  const left = await a.call({ method: "summarize", params: { clientId: "A" } });
  const right = await b.call({
    method: "summarize",
    params: { clientId: "B" },
  });
  assert.notDeepEqual(left, right);
  console.log(
    "Confirmed TS/TS counterexample: create existing subdirectory emits no op, leaves equal public state but unequal raw summaries.",
  );
  console.log(JSON.stringify({ left, right }));
} finally {
  await Promise.all(peers.map((p) => p.close()));
}
