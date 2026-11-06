import assert from "node:assert/strict";
import { Peer } from "./transport.js";
import type { Request } from "./protocol.js";

const peers = [new Peer("ts", 0, []), new Peer("swift", 1, [])];
try {
  for (const [name, edit] of [
    ["counter", { kind: "increment", amount: 7 }],
    ["map", { kind: "set", key: "key", value: 7 }],
  ] as const) {
    const calls: Request[] = [
      { method: "reset", params: {} },
      {
        method: "createClient",
        params: {
          clientId: "A",
          ddsType: `https://graph.microsoft.com/types/${name}`,
          channelId: name,
          sequenceNumber: 0,
          summary: null,
          flushMode: "turnBased",
        },
      },
      { method: "edit", params: { clientId: "A", edit } },
      { method: "rollback", params: { clientId: "A" } },
      { method: "state", params: { clientId: "A" } },
      { method: "summarize", params: { clientId: "A" } },
      { method: "edit", params: { clientId: "A", edit } },
      { method: "flush", params: { clientId: "A" } },
    ];
    for (const call of calls)
      assert.deepEqual(
        await peers[0]?.call(call),
        await peers[1]?.call(call),
        `${name} ${call.method}`,
      );
    console.log(
      `${name}: turn-based submit, rollback, state, summary and flush match`,
    );
  }
} finally {
  await Promise.all(peers.map((p) => p.close()));
}
