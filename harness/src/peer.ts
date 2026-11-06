import { createInterface } from "node:readline";
import { z } from "zod";
import { SharedCounter } from "@fluidframework/counter/internal";
import {
  MockContainerRuntime,
  MockContainerRuntimeFactory,
  MockFluidDataStoreRuntime,
  MockSharedObjectServices,
} from "@fluidframework/test-runtime-utils/internal";
import type { ISequencedDocumentMessage } from "@fluidframework/driver-definitions/internal";
import {
  ddsType,
  outboundSchema,
  requestSchema,
  type Outbound,
  type Request,
} from "./protocol.js";
class CaptureFactory extends MockContainerRuntimeFactory {
  readonly outbound: Outbound[] = [];
  override pushMessage(message: Partial<ISequencedDocumentMessage>): void {
    this.outbound.push(
      outboundSchema.parse({
        clientId: message.clientId,
        clientSequenceNumber: message.clientSequenceNumber,
        referenceSequenceNumber: message.referenceSequenceNumber,
        contents: message.contents,
      }),
    );
  }
  drain(): Outbound[] {
    return this.outbound.splice(0);
  }
}
type Client = {
  store: MockFluidDataStoreRuntime;
  counter: SharedCounter;
  runtime: MockContainerRuntime;
  factory: CaptureFactory;
};
const clients = new Map<string, Client>();
async function handle(request: Request): Promise<unknown> {
  if (request.method === "hello")
    return { implementation: "ts", ddsTypes: [ddsType] };
  const p = request.params;
  if (request.method === "createClient") {
    const p = request.params;
    if (clients.has(p.clientId)) throw new Error("Duplicate client");
    if (p.summary === null && p.sequenceNumber !== 0)
      throw new Error("Empty client must join at zero");
    const store = new MockFluidDataStoreRuntime({ clientId: p.clientId });
    store.idCompressor = undefined; // The mock creates one by default, even without an override.
    const factory = new CaptureFactory(); // Default is Immediate, without grouped batching.
    const runtime = new MockContainerRuntime(store, factory, undefined, {
      minimumSequenceNumber: p.sequenceNumber,
    });
    const services =
      p.summary === null
        ? new MockSharedObjectServices({})
        : MockSharedObjectServices.createFromSummary(p.summary);
    services.deltaConnection = store.createDeltaConnection();
    const counterFactory = SharedCounter.getFactory();
    const counter =
      p.summary === null
        ? counterFactory.create(store, p.channelId)
        : await counterFactory.load(
            store,
            p.channelId,
            services,
            counterFactory.attributes,
          );
    if (p.summary === null) counter.connect(services);
    if (factory.drain().length !== 0)
      throw new Error("Unexpected create outbound");
    clients.set(p.clientId, { store, counter, runtime, factory });
    return {};
  }
  const c = clients.get(p.clientId);
  if (!c) throw new Error(`Unknown client ${p.clientId}`);
  switch (request.method) {
    case "edit":
      c.counter.increment(request.params.edit.amount);
      return { outbound: c.factory.drain() };
    case "process":
      c.runtime.process({ ...request.params.message, timestamp: 0 });
      return { outbound: c.factory.drain() };
    case "state":
      return { state: { value: c.counter.value } };
    case "summarize":
      return { summary: (await c.counter.summarize()).summary };
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
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
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
