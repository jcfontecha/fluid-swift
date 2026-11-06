import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import {
  ddsType,
  outboundResult,
  summarySchema,
  type Outbound,
  type Message,
} from "./protocol.js";
import { Peer } from "./transport.js";
import { Random } from "./random.js";
type Client = {
  id: string;
  peer: Peer;
  cursor: number;
  reference: number;
  csn: number;
  pending: number[];
};
export class Session {
  private clients: Client[] = [];
  private queue: Outbound[] = [];
  private log: Message[] = [];
  private nextId = 0;
  constructor(
    private readonly peers: Peer[],
    private readonly random: Random,
  ) {}
  async create(source?: Client): Promise<void> {
    const id = `client-${this.nextId++}`;
    const peer = this.peers[(this.nextId - 1) % this.peers.length];
    if (!peer) throw new Error("No peers");
    if (source && source.pending.length !== 0)
      throw new Error("Join source has pending ops");
    const summary = source
      ? summarySchema.parse(
          z
            .object({ summary: summarySchema })
            .parse(
              await source.peer.call({
                method: "summarize",
                params: { clientId: source.id },
              }),
            ).summary,
        )
      : null;
    const cursor = source?.cursor ?? 0;
    const result = await peer.call({
      method: "createClient",
      params: {
        clientId: id,
        ddsType,
        channelId: "counter",
        sequenceNumber: cursor,
        summary,
      },
    });
    z.object({}).strict().parse(result);
    this.clients.push({
      id,
      peer,
      cursor,
      reference: cursor,
      csn: 0,
      pending: [],
    });
  }
  private capture(c: Client, result: unknown): void {
    for (const message of outboundResult.parse(result).outbound) {
      if (message.clientId !== c.id)
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
  private async edit(c: Client, amount: number): Promise<void> {
    this.capture(
      c,
      await c.peer.call({
        method: "edit",
        params: { clientId: c.id, edit: { kind: "increment", amount } },
      }),
    );
  }
  private sequence(): void {
    const op = this.queue.shift();
    if (!op) return;
    const author = this.clients.find((c) => c.id === op.clientId);
    if (!author) throw new Error("Unknown sender");
    author.reference = op.referenceSequenceNumber;
    this.log.push({
      ...op,
      sequenceNumber: this.log.length + 1,
      minimumSequenceNumber: Math.min(...this.clients.map((c) => c.reference)),
      type: "op",
    });
  }
  private async deliver(c: Client, k: number): Promise<void> {
    for (let i = 0; i < k && c.cursor < this.log.length; i++) {
      const message = this.log[c.cursor];
      if (!message) throw new Error("Missing log message");
      if (
        message.clientId === c.id &&
        c.pending.shift() !== message.clientSequenceNumber
      )
        throw new Error("Unexpected local ack");
      c.cursor++;
      this.capture(
        c,
        await c.peer.call({
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
    let summaryText: string | undefined;
    for (const c of this.clients) {
      if (c.pending.length)
        throw new Error("Pending messages after checkpoint");
      const state = z
        .object({ state: z.object({ value: z.number() }).strict() })
        .strict()
        .parse(
          await c.peer.call({ method: "state", params: { clientId: c.id } }),
        ).state;
      const summary = z
        .object({ summary: summarySchema })
        .strict()
        .parse(
          await c.peer.call({
            method: "summarize",
            params: { clientId: c.id },
          }),
        ).summary;
      const text = JSON.stringify(summary);
      if (baseline !== undefined && !isDeepStrictEqual(state, baseline))
        throw new Error(
          `State mismatch at ${c.id}: ${JSON.stringify(baseline)} != ${JSON.stringify(state)}`,
        );
      if (summaryText !== undefined && text !== summaryText)
        throw new Error(
          `Summary mismatch at ${c.id}: ${summaryText} != ${text}`,
        );
      baseline = state;
      summaryText = text;
    }
  }
  async run(): Promise<void> {
    for (const peer of this.peers)
      z.object({
        implementation: z.literal(peer.kind),
        ddsTypes: z
          .array(z.string())
          .refine((types) => types.includes(ddsType)),
      })
        .strict()
        .parse(await peer.call({ method: "hello", params: {} }));
    const initial = 2 + this.random.int(4);
    for (let i = 0; i < initial; i++) await this.create();
    for (let i = 0; i < 120; i++) {
      const c = this.random.pick(this.clients);
      const step = this.random.int(100);
      if (step < 45) await this.edit(c, this.random.int(201) - 100);
      else if (step < 61) this.sequence();
      else if (step < 82) await this.deliver(c, 1 + this.random.int(8));
      else if (step < 90 && this.clients.length < 10) {
        const candidates = this.clients.filter(
          (client) => client.pending.length === 0,
        );
        if (candidates.length) await this.create(this.random.pick(candidates));
      } else if (step < 96) await this.checkpoint();
      else {
        // Float addition isn't associative, even for integer-valued doubles. Isolate
        // boundary probes so the oracle doesn't legitimately diverge from itself.
        await this.checkpoint();
        const amount =
          (2 ** 53 + this.random.int(9) * 2) * (this.random.int(2) ? 1 : -1);
        await this.edit(c, amount);
        await this.checkpoint();
        await this.edit(c, -amount);
        await this.checkpoint();
      }
    }
    await this.checkpoint();
  }
}
