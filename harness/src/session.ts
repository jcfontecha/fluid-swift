import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import {
  ddsType,
  outboundResult,
  outboundSchema as importOutbound,
  summarySchema,
  type Outbound,
  type Message,
  type Request,
} from "./protocol.js";
import { Peer } from "./transport.js";
import {
  factories,
  generate,
  queryDrivenGenerators,
  type DDSName,
  type SessionHistory,
} from "./dds.js";
import { Random } from "./random.js";
interface DirectoryState {
  entries: unknown[];
  children: [string, DirectoryState][];
}
const directoryState: z.ZodType<DirectoryState> = z.lazy(() =>
  z.object({
    entries: z.array(z.unknown()),
    children: z.array(z.tuple([z.string(), directoryState])),
  }),
);
type Client = {
  id: string;
  wireId: string;
  peer: Peer;
  twin?: Peer;
  cursor: number;
  reference: number;
  csn: number;
  pending: number[];
  summarizer: boolean;
};
export class Session {
  private clients: Client[] = [];
  private queue: Outbound[] = [];
  private log: Message[] = [];
  private nextId = 0;
  constructor(
    private readonly peers: Peer[],
    private readonly random: Random,
    private readonly name: DDSName = "counter",
  ) {}
  private async call(c: Client, request: Request): Promise<unknown> {
    const result = await c.peer.call(request);
    if (c.twin) {
      const subjectText = c.peer.resultText;
      await c.twin.call(request);
      const twinText = c.twin.resultText;
      if (subjectText !== twinText) {
        throw new Error(
          `Twin ${request.method} mismatch at ${c.id}: ${subjectText} != ${twinText}`,
        );
      }
    }
    if (request.method === "membership" || request.method === "disconnect") {
      this.capture(c, result);
    }
    return result;
  }
  async create(source?: Client, summarizerPeer?: Peer): Promise<void> {
    const id = summarizerPeer
      ? `summarizer-${this.peers.indexOf(summarizerPeer)}`
      : `client-${this.nextId++}`;
    const peer = summarizerPeer ?? this.peers[(this.nextId - 1) % this.peers.length];
    if (source && !source.summarizer)
      throw new Error("Join source must be a non-editing summarizer");
    if (!peer) throw new Error("No peers");
    if (source && source.pending.length !== 0)
      throw new Error("Join source has pending ops");
    const summary = source
      ? summarySchema.parse(
          z.object({ summary: summarySchema }).parse(
            await this.call(source, {
              method: "summarize",
              params: { clientId: source.id },
            }),
          ).summary,
        )
      : null;
    const cursor = source?.cursor ?? 0;
    const twin = peer === this.peers[0] ? undefined : this.peers[0];
    const client: Client = {
      id,
      wireId: id,
      peer,
      twin,
      cursor,
      reference: cursor,
      csn: 0,
      pending: [],
      summarizer: summarizerPeer !== undefined,
    };
    const result = await this.call(client, {
      method: "createClient",
      params: {
        clientId: id,
        ddsType: factories[this.name].type,
        channelId: this.name,
        sequenceNumber: cursor,
        summary,
        members: [...this.clients.map((c) => c.wireId), id],
      },
    });
    z.object({}).strict().parse(result);
    for (const c of this.clients)
      await this.call(c, {
        method: "membership",
        params: {
          clientId: c.id,
          members: [...this.clients.map((c) => c.wireId), id],
        },
      });
    this.clients.push(client);
  }
  private capture(c: Client, result: unknown): void {
    for (const message of outboundResult.parse(result).outbound) {
      if (message.clientId !== c.wireId)
        throw new Error("Outbound clientId mismatch");
      if (message.referenceSequenceNumber !== c.cursor)
        throw new Error(`Wrong referenceSequenceNumber for ${c.id}`);
      if (message.clientSequenceNumber <= c.csn)
        throw new Error(`Non-increasing clientSequenceNumber for ${c.id}`);
      c.csn = message.clientSequenceNumber;
      c.pending.push(c.csn);
      this.queue.push(message);
    }
  }
  private async edit(
    c: Client,
    edit: import("./protocol.js").Edit,
  ): Promise<void> {
    if (
      this.name === "directory" &&
      "path" in edit &&
      edit.path !== undefined
    ) {
      const response = z
        .object({ state: directoryState })
        .parse(
          await this.call(c, { method: "state", params: { clientId: c.id } }),
        );
      let current = response.state;
      let path = "/";
      // Upstream chooses a directory by walking children, with a chance to stop at each level.
      while (
        current.children.length > 0 &&
        this.random.int(current.children.length + 1) !== 0
      ) {
        const [name, next] = this.random.pick(current.children);
        path = `${path === "/" ? "" : path}/${name}`;
        current = next;
      }
      if (edit.kind === "deleteSubDirectory" && current.children.length > 0) {
        edit = { ...edit, path, name: this.random.pick(current.children)[0] };
      } else {
        edit = { ...edit, path };
      }
    }

    this.capture(
      c,
      await this.call(c, {
        method: "edit",
        params: { clientId: c.id, edit },
      }),
    );
  }
  private sequence(): void {
    const op = this.queue.shift();
    if (!op) return;
    const author = this.clients.find((c) => c.wireId === op.clientId);
    if (!author) throw new Error("Unknown sender");
    author.reference = op.referenceSequenceNumber;
    this.log.push({
      ...op,
      sequenceNumber: this.log.length + 1,
      // Read-only summarizers never submit reference updates and do not constrain MSN.
      minimumSequenceNumber: Math.min(
        ...this.clients.filter((c) => !c.summarizer).map((c) => c.reference),
      ),
      type: "op",
    });
  }
  private async deliver(c: Client, k: number): Promise<void> {
    for (let i = 0; i < k && c.cursor < this.log.length; i++) {
      const message = this.log[c.cursor];
      if (!message) throw new Error("Missing log message");
      if (
        message.clientId === c.wireId &&
        c.pending.shift() !== message.clientSequenceNumber
      )
        throw new Error("Unexpected local ack");
      c.cursor++;
      this.capture(
        c,
        await this.call(c, {
          method: "process",
          params: { clientId: c.id, message },
        }),
      );
    }
  }
  async checkpoint(): Promise<void> {
    do {
      while (this.queue.length) this.sequence();
      for (const c of this.clients)
        await this.deliver(c, this.log.length - c.cursor);
    } while (this.queue.length);
    let baseline: unknown;

    for (const c of this.clients) {
      if (c.pending.length)
        throw new Error("Pending messages after checkpoint");
      await this.call(c, { method: "queries", params: { clientId: c.id } });
      await this.call(c, { method: "events", params: { clientId: c.id } });
      const state = z
        .object({ state: z.unknown() })
        .strict()
        .parse(
          await this.call(c, { method: "state", params: { clientId: c.id } }),
        ).state;
      const summary = z
        .object({ summary: summarySchema })
        .strict()
        .parse(
          await this.call(c, {
            method: "summarize",
            params: { clientId: c.id },
          }),
        ).summary;
      if (baseline !== undefined && !isDeepStrictEqual(state, baseline))
        throw new Error(
          `State mismatch at ${c.id}: ${JSON.stringify(baseline)} != ${JSON.stringify(state)}`,
        );
      baseline = state;
      // Editor summaries remain byte-checked above; only read-only replicas supply loads.
      if (!c.summarizer) continue;
      // Use both configured implementations. TS self-checks can certify unported DDSes.
      for (const peer of this.peers) {
        const id = `cross-load-${this.crossLoadNumber++}`;
        await peer.call({
          method: "createClient",
          params: {
            clientId: id,
            ddsType: factories[this.name].type,
            channelId: this.name,
            sequenceNumber: c.cursor,
            summary,
            members: this.clients.map((client) => client.wireId),
          },
        });
        const loaded = z
          .object({ state: z.unknown() })
          .parse(
            await peer.call({ method: "state", params: { clientId: id } }),
          ).state;
        if (!isDeepStrictEqual(loaded, state)) {
          throw new Error(
            `Cross-load mismatch from ${c.id} in ${peer.kind}: ${JSON.stringify(state)} != ${JSON.stringify(loaded)}`,
          );
        }
        await peer.call({ method: "disposeClient", params: { clientId: id } });
      }
    }
  }
  private async reconnect(c: Client): Promise<void> {
    await this.checkpoint();
    await this.call(c, { method: "disconnect", params: { clientId: c.id } });
    for (const other of this.clients)
      if (other !== c)
        await this.call(other, {
          method: "membership",
          params: {
            clientId: other.id,
            members: this.clients.filter((x) => x !== c).map((x) => x.wireId),
          },
        });
    // Offline local writes must survive and resubmit, without optimistic replay. Summary-block
    // edits are local-only and must reach every replica identically, so they are not made here.
    if (this.name !== "shared-summary-block")
      for (let i = 0; i < 3; i++)
        await this.edit(
          c,
          generate(
            this.name,
            this.random,
            await this.queries(c),
            this.historyFor(c),
          ),
        );
    const newClientId = `${c.id}-reconnect-${this.reconnectNumber++}`;
    c.wireId = newClientId;
    c.csn = 0;
    const result = z
      .object({
        clientId: z.literal(newClientId),
        outbound: z.array(importOutbound),
      })
      .parse(
        await this.call(c, {
          method: "reconnect",
          params: { clientId: c.id, newClientId },
        }),
      );
    this.capture(c, { outbound: result.outbound });
    for (const other of this.clients)
      await this.call(other, {
        method: "membership",
        params: {
          clientId: other.id,
          members: this.clients.map((x) => x.wireId),
        },
      });
  }
  /** What the session knows about concurrent operations, for generators that must avoid them. */
  private historyFor(c: Client): SessionHistory {
    return {
      log: this.log,
      queue: this.queue,
      cursor: c.cursor,
      wireId: c.wireId,
    };
  }
  /** The acting client's own queries, for generators that choose by eligibility. */
  private async queries(c: Client): Promise<unknown> {
    if (!queryDrivenGenerators.includes(this.name)) return undefined;
    return z
      .object({ queries: z.unknown() })
      .strict()
      .parse(
        await this.call(c, { method: "queries", params: { clientId: c.id } }),
      ).queries;
  }
  private async arrayQueries(c: Client): Promise<{
    insertIds: string[];
    moveIds: [string, string][];
  }> {
    return z
      .object({
        insertIds: z.array(z.string()),
        moveIds: z.array(z.tuple([z.string(), z.string()])),
      })
      .parse(await this.queries(c));
  }
  private reconnectNumber = 0;
  private crossLoadNumber = 0;
  private async lifecycle(): Promise<void> {
    const subject = this.clients.filter((c) => !c.summarizer)[1];
    if (!subject) throw new Error("Lifecycle needs a subject");
    const apply = async (edit: import("./protocol.js").Edit): Promise<void> => {
      await this.edit(subject, edit);
      await this.checkpoint();
    };
    switch (this.name) {
      case "map":
      case "directory":
        await apply({
          kind: "set",
          key: "a",
          value: null,
          valueKind: "undefined",
        });
        await apply({
          kind: "set",
          key: "b",
          value: { type: "__fluid_handle__", url: "/handles/a" },
          valueKind: "handle",
        });
        break;
      case "task-manager":
        await apply({ kind: "volunteer", key: "a" });
        await apply({ kind: "complete", key: "a" });
        await apply({ kind: "subscribe", key: "b" });
        await apply({ kind: "abandon", key: "b" });
        break;
      case "ordered-collection":
        await apply({ kind: "add", value: 1 });
        await apply({ kind: "acquire", result: "complete" });
        await apply({ kind: "add", value: 2 });
        await apply({ kind: "acquire", result: "release" });
        break;
      case "pact-map":
        await apply({ kind: "set", key: "a", value: 1 });
        await apply({ kind: "delete", key: "a" });
        break;
      case "shared-array": {
        await apply({ kind: "insert", value: "1", index: 0 });
        await apply({ kind: "insert", value: "2", index: 1 });
        await apply({ kind: "move", oldIndex: 0, newIndex: 2 });
        const moved = await this.arrayQueries(subject);
        const [oldEntryId, newEntryId] = moved.moveIds[0] ?? [];
        if (oldEntryId === undefined || newEntryId === undefined)
          throw new Error("Lifecycle move was not tracked");
        await apply({ kind: "toggleMove", oldEntryId, newEntryId });
        const toggled = await this.arrayQueries(subject);
        const entryId = toggled.insertIds[0];
        if (entryId === undefined)
          throw new Error("Lifecycle insert was not tracked");
        await apply({ kind: "toggle", entryId });
        await apply({ kind: "insertBulkAfter", ref: "2", values: ["3", "4"] });
        await apply({ kind: "delete", index: 0, key: "" });
        break;
      }
      default:
        break;
    }
  }
  async run(): Promise<void> {
    for (const peer of this.peers)
      z.object({
        implementation: z.literal(peer.kind),
        ddsTypes: z
          .array(z.string())
          .refine((types) => types.includes(factories[this.name].type), {
            message: `${this.name} is not implemented by ${peer.kind}`,
          }),
      })
        .strict()
        .parse(await peer.call({ method: "hello", params: {} }));
    for (const peer of this.peers) await this.create(undefined, peer);
    const initial = 2 + this.random.int(4);
    for (let i = 0; i < initial; i++) await this.create();
    await this.lifecycle();
    for (let i = 0; i < 120; i++) {
      const c = this.random.pick(this.clients.filter((client) => !client.summarizer));
      const step = this.random.int(100);
      if (step < 45) {
        const edit = generate(
          this.name,
          this.random,
          await this.queries(c),
          this.historyFor(c),
        );
        if (this.name === "shared-summary-block") {
          for (const client of this.clients) await this.edit(client, edit);
        } else await this.edit(c, edit);
      } else if (step < 61) this.sequence();
      else if (step < 82) await this.deliver(c, 1 + this.random.int(8));
      else if (step < 90 && this.clients.filter((client) => !client.summarizer).length < 10) {
        await this.checkpoint();
        const candidates = this.clients.filter(
          (client) => client.summarizer && client.pending.length === 0,
        );
        if (candidates.length) await this.create(this.random.pick(candidates));
      } else if (step < 96) await this.checkpoint();
      else await this.reconnect(c);
    }
    await this.checkpoint();
  }
}
