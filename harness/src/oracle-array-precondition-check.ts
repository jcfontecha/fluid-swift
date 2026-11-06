import assert from "node:assert/strict";
import { z } from "zod";
import { Peer } from "./transport.js";
import { outboundResult, type Edit, type Outbound } from "./protocol.js";

// legacy-dds SharedArray drops a remote move undo while a local delete is pending.
// Later undeleting that value reveals different live positions, in one TS process.
const peer = new Peer("ts", 0, []);
let sequenceNumber = 0;
async function edit(clientId: string, edit: Edit): Promise<Outbound> {
  const result = outboundResult.parse(
    await peer.call({ method: "edit", params: { clientId, edit } }),
  );
  assert.equal(result.outbound.length, 1);
  const message = result.outbound[0];
  assert.ok(message);
  return message;
}
async function deliver(message: Outbound): Promise<void> {
  const sequenced = {
    ...message,
    sequenceNumber: ++sequenceNumber,
    minimumSequenceNumber: 0,
    type: "op" as const,
  };
  for (const clientId of ["A", "B"]) {
    assert.deepEqual(
      await peer.call({
        method: "process",
        params: { clientId, message: sequenced },
      }),
      { outbound: [] },
    );
  }
}
async function states(): Promise<unknown[]> {
  const result: unknown[] = [];
  for (const clientId of ["A", "B"])
    result.push(await peer.call({ method: "state", params: { clientId } }));
  return result;
}
async function queries(
  clientId: string,
): Promise<{ moveIds: [string, string][]; deleteIds: string[] }> {
  return z
    .object({
      queries: z.object({
        moveIds: z.array(z.tuple([z.string(), z.string()])),
        deleteIds: z.array(z.string()),
      }),
    })
    .parse(await peer.call({ method: "queries", params: { clientId } }))
    .queries;
}
try {
  for (const clientId of ["A", "B"]) {
    await peer.call({
      method: "createClient",
      params: {
        clientId,
        ddsType: "https://graph.microsoft.com/types/SharedArray",
        channelId: "array",
        sequenceNumber: 0,
        summary: null,
        members: ["A", "B"],
      },
    });
  }
  await deliver(await edit("A", { kind: "insert", value: "1", index: 0 }));
  await deliver(await edit("A", { kind: "insert", value: "2", index: 1 }));
  await deliver(await edit("A", { kind: "move", oldIndex: 0, newIndex: 2 }));
  assert.deepEqual(await states(), [{ state: ["2", "1"] }, { state: ["2", "1"] }]);
  const [oldEntryId, newEntryId] = (await queries("A")).moveIds[0] ?? [];
  assert.ok(oldEntryId !== undefined && newEntryId !== undefined);
  const undo = await edit("A", { kind: "toggleMove", oldEntryId, newEntryId });
  const deletion = await edit("B", { kind: "delete", key: "", index: 1 });
  await deliver(undo);
  await deliver(deletion);
  assert.deepEqual(await states(), [{ state: ["2"] }, { state: ["2"] }]);
  // B undeletes "1": the deleted entry is the only one B tracks as deleted.
  const [deletedEntryId] = (await queries("B")).deleteIds;
  assert.ok(deletedEntryId !== undefined);
  await deliver(await edit("B", { kind: "toggle", entryId: deletedEntryId }));
  assert.deepEqual(await states(), [{ state: ["1", "2"] }, { state: ["2", "1"] }]);
  console.log(
    'Confirmed TS-only Array convergence counterexample: A=["1","2"], B=["2","1"]',
  );
} finally {
  await peer.close();
}
