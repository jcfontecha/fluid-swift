import { setEntropyContext } from "./entropy.js";
console.log = (...args: unknown[]) => console.error(...args);
import { createInterface } from "node:readline";
import { z } from "zod";
import {
  wireReplacer,
  createAdapter,
  factories,
  names,
  type Adapter,
} from "./dds.js";
import {
  MockContainerRuntimeForReconnection,
  MockContainerRuntimeFactoryForReconnection,
  MockContainerRuntimeFactory,
  MockFluidDataStoreRuntime,
  MockSharedObjectServices,
} from "@fluidframework/test-runtime-utils/internal";
import { FlushMode } from "@fluidframework/runtime-definitions/internal";
import type { ISequencedDocumentMessage } from "@fluidframework/driver-definitions/internal";
import {
  ddsType,
  outboundSchema,
  requestSchema,
  type Outbound,
  type Request,
} from "./protocol.js";
class CaptureFactory extends MockContainerRuntimeFactoryForReconnection {
  readonly outbound: Outbound[] = [];
  override pushMessage(message: Partial<ISequencedDocumentMessage>): void {
    this.outbound.push(
      outboundSchema.parse({
        clientId: message.clientId,
        clientSequenceNumber: message.clientSequenceNumber,
        referenceSequenceNumber: message.referenceSequenceNumber,
        contents: JSON.parse(JSON.stringify(message.contents)),
      }),
    );
  }
  drain(): Outbound[] {
    return this.outbound.splice(0);
  }
}
// Same reconnection algorithm as 3.11.0, with the server-assigned ID supplied by
// the trace rather than uuid(), so reconnect traces remain byte-replayable.
class ReconnectionRuntime extends MockContainerRuntimeForReconnection {
  private online = true;
  nextClientId = "";
  override get connected(): boolean {
    return this.online;
  }
  override set connected(value: boolean) {
    if (value === this.online) return;
    this.emit(value ? "connected" : "disconnected");
    this.online = value;
    if (value) {
      this.processPendingMessages(this.pendingRemoteMessages);
      this.pendingRemoteMessages.length = 0;
      this.deltaManager.clientSequenceNumber = 0;
      this.clientId = this.nextClientId;
      this.dataStoreRuntime.clientId = this.clientId;
      this.factory.quorum.addMember(this.clientId, {});
      const pending = this.pendingMessages.splice(0);
      this.reSubmitMessages(pending);
    } else {
      this.factory.clearOutstandingClientMessages(this.clientId);
      this.factory.quorum.removeMember(this.clientId);
      for (const op of this.outbox)
        this.addPendingMessage(
          op.content,
          op.localOpMetadata,
          ++this.deltaManager.clientSequenceNumber,
        );
      this.outbox.length = 0;
    }
    this.dataStoreRuntime.setConnectionState(value, this.clientId);
  }
}
type Client = {
  store: MockFluidDataStoreRuntime;
  adapter: Adapter;
  runtime: ReconnectionRuntime;
  factory: CaptureFactory;
};
const clients = new Map<string, Client>();
const callCounts = new Map<string, number>();
async function handle(request: Request): Promise<unknown> {
  if (request.method === "reset") {
    for (const c of clients.values()) {
      c.store.dispose();
      c.runtime.deltaManager.dispose();
    }
    clients.clear();
    callCounts.clear();
    return {};
  }
  if (request.method === "hello")
    return {
      implementation: "ts",
      ddsTypes: names.map((name) => factories[name].type),
    };
  const p = request.params;
  const count = callCounts.get(`${p.clientId}:${request.method}`) ?? 0;
  callCounts.set(`${p.clientId}:${request.method}`, count + 1);
  setEntropyContext(`${p.clientId}:${count}:${request.method}`);
  if (request.method === "createClient") {
    const p = request.params;
    if (clients.has(p.clientId)) throw new Error("Duplicate client");
    if (p.summary === null && p.sequenceNumber !== 0)
      throw new Error("Empty client must join at zero");
    const store = new MockFluidDataStoreRuntime({ clientId: p.clientId });
    store.idCompressor = undefined; // The mock creates one by default, even without an override.
    const factory = new CaptureFactory(); // Default is Immediate, without grouped batching.
    for (const id of p.members ?? [p.clientId])
      factory.quorum.addMember(id, {});
    const runtime = new ReconnectionRuntime(
      store,
      factory,
      {
        flushMode:
          p.flushMode === "turnBased"
            ? FlushMode.TurnBased
            : FlushMode.Immediate,
      },
      {
        minimumSequenceNumber: p.sequenceNumber,
      },
    );
    const services =
      p.summary === null
        ? new MockSharedObjectServices({})
        : MockSharedObjectServices.createFromSummary(p.summary);
    services.deltaConnection = store.createDeltaConnection();
    const name = names.find((name) => factories[name].type === p.ddsType);
    if (!name) throw Error(`Unknown DDS ${p.ddsType}`);
    const adapter = await createAdapter(
      name,
      store,
      p.channelId,
      services,
      p.summary !== null,
    );
    if (factory.drain().length !== 0)
      throw new Error("Unexpected create outbound");
    clients.set(p.clientId, { store, adapter, runtime, factory });
    return {};
  }
  const c = clients.get(p.clientId);
  if (!c) throw new Error(`Unknown client ${p.clientId}`);
  switch (request.method) {
    case "edit":
      c.adapter.edit(request.params.edit);
      await new Promise<void>((resolve) => setImmediate(resolve));
      return { outbound: c.factory.drain() };
    case "process":
      c.runtime.process({ ...request.params.message, timestamp: 0 });
      await new Promise<void>((resolve) => setImmediate(resolve));
      return { outbound: c.factory.drain() };
    case "flush":
      c.runtime.flush();
      return { outbound: c.factory.drain() };
    case "rollback":
      c.runtime.rollback?.();
      return { outbound: c.factory.drain() };
    case "stash":
      c.store.applyStashedOp({
        address: c.adapter.channel.id,
        contents: request.params.contents,
      });
      return { outbound: c.factory.drain() };
    case "disconnect":
      c.runtime.connected = false;
      return { outbound: c.factory.drain() };
    case "reconnect":
      c.runtime.nextClientId = request.params.newClientId;
      c.runtime.connected = true;
      return { clientId: c.runtime.clientId, outbound: c.factory.drain() };
    case "membership":
      for (const id of c.factory.quorum.getMembers().keys())
        if (!request.params.members.includes(id))
          c.factory.quorum.removeMember(id);
      for (const id of request.params.members)
        if (!c.factory.quorum.getMember(id)) c.factory.quorum.addMember(id, {});
      return { outbound: c.factory.drain() };
    case "events":
      return { events: c.adapter.events.splice(0) };
    case "queries":
      return { queries: c.adapter.queries?.() ?? {} };
    case "state":
      return { state: await c.adapter.state() };
    case "summarize":
      return { summary: (await c.adapter.channel.summarize()).summary };
    case "disposeClient":
      c.store.dispose();
      c.runtime.deltaManager.dispose();
      clients.delete(p.clientId);
      return {};
  }
}
const envelope = z.object({ jsonrpc: z.literal("2.0"), id: z.number().int() });
for await (const line of createInterface({ input: process.stdin })) {
  let id = 0;
  try {
    const raw: unknown = JSON.parse(line);
    id = envelope.parse(raw).id;
    const request = requestSchema.parse(raw);
    const result = await handle(request);
    process.stdout.write(
      JSON.stringify({ jsonrpc: "2.0", id, result }, wireReplacer) + "\n",
    );
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        jsonrpc: "2.0",
        id,
        error: {
          code: -32000,
          message: error instanceof Error ? error.message : String(error),
        },
      }) + "\n",
    );
  }
}
