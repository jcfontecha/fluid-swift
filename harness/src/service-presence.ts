// Service mode (presence): Swift and TS clients exchange presence over real tinylicious.
// The TS side is the real 3.11.0 presence reached through fluid-static's `getPresenceAlpha`, which
// acquires the presence container extension. See harness/PROTOCOL.md, "Service mode (presence)".

import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import type { IContainer } from '@fluidframework/container-definitions/internal';
import { loadExistingContainer } from '@fluidframework/container-loader/internal';
import { isInternalFluidContainer, createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { getPresenceAlpha } from '@fluidframework/fluid-static/alpha';
import { SharedMap } from 'fluid-framework/legacy';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { RouterliciousDocumentServiceFactory } from '@fluidframework/routerlicious-driver/internal';
import { InsecureTinyliciousTokenProvider, InsecureTinyliciousUrlResolver } from '@fluidframework/tinylicious-driver/internal';
import { Notifications, StateFactory } from '@fluid-internal/presence-runtime/states';
import type { PresenceWithNotifications } from '@fluid-internal/presence-definitions';
import { Random } from './random.js';

const root = resolve(import.meta.dirname, '../..');
const port = 7076;
const endpoint = `http://localhost:${port}`;
const scratchPath = process.argv.find(arg => arg.startsWith('--scratch-path='))?.slice('--scratch-path='.length) ?? '.build/presence';
// presence-runtime/src/runtime/extension/containerPresence.ts `extensionId`.
const extensionAddress = '/ext/dis:bb89f4c0-80fd-4f0c-8469-4f2848ee7f4a/';
const presenceMessageTypes = ['Pres:ClientJoin', 'Pres:DatastoreUpdate'];

execFileSync('swift', ['build', '--scratch-path', scratchPath, '--product', 'FluidServicePeer'], { cwd: root, stdio: 'inherit' });

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function until(test: () => boolean | Promise<boolean>, label: string): Promise<void> {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await test()) return;
    await sleep(20);
  }
  throw new Error(`Timeout: ${label}`);
}

// ---- Views: what one client observes. Attendee IDs are session IDs, replaced by labels to compare. ----

interface Cursor { x: number; y: number }
interface Item { n: number }
type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
const jsonSchema: z.ZodType<Json> = z.lazy(() => z.union([
  z.null(), z.boolean(), z.number(), z.string(), z.array(jsonSchema), z.record(z.string(), jsonSchema),
]));
const viewSchema = z.object({
  attendees: z.array(z.object({ id: z.string(), status: z.enum(['Connected', 'Disconnected']) })),
  cursor: z.object({
    local: jsonSchema,
    remotes: z.array(z.object({ attendee: z.string(), value: jsonSchema, revision: z.number() })),
  }),
  items: z.object({
    local: z.array(z.tuple([z.string(), jsonSchema])),
    remotes: z.array(z.object({ attendee: z.string(), items: z.array(z.tuple([z.string(), jsonSchema])) })),
  }),
  notifications: z.array(z.object({ attendee: z.string(), name: z.string(), args: z.array(jsonSchema) })),
});
type RawView = z.infer<typeof viewSchema>;

interface View {
  attendees: [string, string][];
  cursor: { local: Json; remotes: [string, Json, number][] };
  items: { local: [string, Json][]; remotes: [string, [string, Json][]][] };
  notifications: Record<string, [string, Json[]][]>;
}
function byFirst<T extends [string, ...unknown[]]>(entries: T[]): T[] {
  return [...entries].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}
function normalize(raw: RawView, labels: Map<string, string>): View {
  const label = (id: string): string => {
    const found = labels.get(id);
    assert(found !== undefined, `unknown attendee ${id}`);
    return found;
  };
  const notifications: Record<string, [string, Json[]][]> = {};
  for (const note of raw.notifications) (notifications[label(note.attendee)] ??= []).push([note.name, note.args]);
  return {
    attendees: byFirst(raw.attendees.map((a): [string, string] => [label(a.id), a.status])),
    cursor: {
      local: raw.cursor.local,
      remotes: byFirst(raw.cursor.remotes.map((r): [string, Json, number] => [label(r.attendee), r.value, r.revision])),
    },
    items: {
      local: byFirst(raw.items.local),
      remotes: byFirst(raw.items.remotes
        .filter(r => r.items.length > 0)
        .map((r): [string, [string, Json][]] => [label(r.attendee), byFirst(r.items)])),
    },
    notifications,
  };
}

// ---- Clients ----

interface Client {
  readonly label: string;
  readonly kind: 'ts' | 'swift';
  attendeeId: string;
  connected: boolean;
  join(): Promise<void>;
  setCursor(value: Cursor): Promise<void>;
  setItem(key: string, value: Item): Promise<void>;
  deleteItem(key: string): Promise<void>;
  notify(label: string, count: number, tag: string[]): Promise<void>;
  disconnect(): Promise<void>;
  reconnect(): Promise<void>;
  view(): Promise<RawView>;
}

const rpcSchema = z.object({
  id: z.number(),
  result: z.unknown().optional(),
  error: z.object({ message: z.string() }).optional(),
});
class Swift {
  readonly child = spawn(resolve(root, scratchPath, 'debug/FluidServicePeer'), [], { cwd: root });
  readonly lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
  id = 0;
  constructor(readonly trace: unknown[]) {
    this.child.stderr.pipe(process.stderr);
  }
  async call(method: string, client: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const request = { jsonrpc: '2.0', id: ++this.id, method, params: { client, ...params } };
    this.trace.push({ request });
    this.child.stdin.write(JSON.stringify(request) + '\n');
    let timer: NodeJS.Timeout | undefined;
    const line = await Promise.race([
      this.lines.next(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('Swift RPC timeout')), 30000);
      }),
    ]).finally(() => clearTimeout(timer));
    assert(!line.done, 'Swift exited');
    const response = rpcSchema.parse(JSON.parse(line.value));
    this.trace.push({ response });
    assert.equal(response.id, this.id);
    if (response.error) throw new Error(response.error.message);
    return response.result;
  }
  async close() {
    if (this.child.exitCode === null) {
      const exited = once(this.child, 'exit');
      this.child.kill();
      await exited;
    }
  }
}

const schema = { initialObjects: { map: SharedMap } };
function props() {
  return {
    urlResolver: new InsecureTinyliciousUrlResolver({ port }),
    documentServiceFactory: new RouterliciousDocumentServiceFactory(new InsecureTinyliciousTokenProvider()),
    codeLoader: {
      load: async () => ({
        module: { fluidExport: createDOProviderContainerRuntimeFactory({ schema, oldestSupportedClient: '2.0.0' }) },
        details: { package: 'service-presence' },
      }),
    },
    clientDetailsOverride: { capabilities: { interactive: true } },
    configProvider: { getRawConfig: (name: string) => name === 'Fluid.Container.ForceWriteConnection' ? true : undefined },
  };
}

class TsClient implements Client {
  readonly kind = 'ts';
  attendeeId = '';
  connected = true;
  readonly received: RawView['notifications'] = [];
  private presence: PresenceWithNotifications | undefined;
  private workspaces: ReturnType<TsClient['register']> | undefined;
  readonly signals: string[] = [];
  constructor(readonly label: string, readonly container: IContainer, private readonly fluid: Parameters<typeof getPresenceAlpha>[0]) {
    container.deltaManager.inboundSignal.on('push', signal => { this.signals.push(JSON.stringify(signal)); });
  }
  private register(presence: PresenceWithNotifications) {
    const states = presence.states.getWorkspace('app:cursors', {
      cursor: StateFactory.latest<Cursor>({ local: { x: 0, y: 0 } }),
      items: StateFactory.latestMap<Item>({ local: {} }),
    });
    const events = presence.notifications.getWorkspace('app:events', {
      ping: Notifications<{ ping: (label: string, count: number, tag: string[]) => void }>({
        ping: (sender, label, count, tag) => {
          this.received.push({ attendee: sender.attendeeId, name: 'ping', args: [label, count, tag] });
        },
      }),
    });
    return { states, events };
  }
  async join(): Promise<void> {
    assert(isInternalFluidContainer(this.fluid));
    const presence = getPresenceAlpha(this.fluid);
    this.presence = presence;
    this.workspaces = this.register(presence);
    this.attendeeId = presence.attendees.getMyself().attendeeId;
  }
  private get ws() {
    assert(this.workspaces !== undefined, 'presence not joined');
    return this.workspaces;
  }
  async setCursor(value: Cursor) { this.ws.states.states.cursor.local = value; }
  async setItem(key: string, value: Item) { this.ws.states.states.items.local.set(key, value); }
  async deleteItem(key: string) { this.ws.states.states.items.local.delete(key); }
  async notify(label: string, count: number, tag: string[]) {
    this.ws.events.notifications.ping.emit.broadcast('ping', label, count, tag);
  }
  async disconnect() {
    this.container.disconnect();
    this.connected = false;
  }
  async reconnect() {
    this.container.connect();
    await until(() => this.container.connectionState === 2, `${this.label} reconnected`);
    this.connected = true;
  }
  async view(): Promise<RawView> {
    assert(this.presence !== undefined);
    const { cursor, items } = this.ws.states.states;
    return viewSchema.parse({
      attendees: [...this.presence.attendees.getAttendees()].map(a => ({ id: a.attendeeId, status: a.getConnectionStatus() })),
      cursor: {
        local: cursor.local,
        remotes: [...cursor.getRemotes()].map(r => ({ attendee: r.attendee.attendeeId, value: r.value, revision: r.metadata.revision })),
      },
      items: {
        local: [...items.local.keys()].map(key => [key, items.local.get(key)]),
        remotes: [...items.getRemotes()].map(r => ({
          attendee: r.attendee.attendeeId,
          items: [...r.items.entries()].map(([key, entry]) => [key, entry.value]),
        })),
      },
      notifications: this.received,
    });
  }
}

class SwiftClient implements Client {
  readonly kind = 'swift';
  attendeeId = '';
  connected = true;
  readonly clientIds = new Set<string>();
  constructor(readonly label: string, private readonly swift: Swift, private readonly document: string) {}
  async open(): Promise<void> {
    await this.swift.call('openM2', this.label, { endpoint, document: this.document });
    await until(async () => (await this.sessionView()).connected, `${this.label} join`);
  }
  async sessionView() {
    return z.object({
      connected: z.boolean(),
      clientId: z.string().nullable(),
      signals: z.array(z.unknown()),
    }).parse(await this.swift.call('view', this.label));
  }
  async join(): Promise<void> {
    this.attendeeId = z.string().parse(await this.swift.call('presenceJoin', this.label));
    this.clientIds.add(z.string().parse((await this.sessionView()).clientId));
  }
  async setCursor(value: Cursor) { await this.swift.call('presenceSet', this.label, { value }); }
  async setItem(key: string, value: Item) { await this.swift.call('presenceMapSet', this.label, { key, value }); }
  async deleteItem(key: string) { await this.swift.call('presenceMapDelete', this.label, { key }); }
  async notify(label: string, count: number, tag: string[]) {
    await this.swift.call('presenceNotify', this.label, { name: 'ping', args: [label, count, tag] });
  }
  async disconnect() {
    await this.swift.call('disconnect', this.label);
    this.connected = false;
  }
  async reconnect() {
    await this.swift.call('reconnect', this.label);
    await until(async () => (await this.sessionView()).connected, `${this.label} reconnected`);
    this.clientIds.add(z.string().parse((await this.sessionView()).clientId));
    this.connected = true;
  }
  async view(): Promise<RawView> {
    return viewSchema.parse(await this.swift.call('presenceView', this.label));
  }
}

// ---- Model: what every connected client must observe ----

interface Published {
  cursor: Cursor;
  revision: number;
  items: Map<string, Item>;
}
class Model {
  readonly joined: string[] = [];
  readonly connected = new Set<string>();
  readonly local = new Map<string, Published>();
  readonly published = new Map<string, Published>();
  readonly received = new Map<string, Map<string, [string, Json[]][]>>();
  join(label: string): void {
    this.joined.push(label);
    this.connected.add(label);
    const state: Published = { cursor: { x: 0, y: 0 }, revision: 0, items: new Map() };
    this.local.set(label, state);
    this.published.set(label, structuredClone(state));
    this.received.set(label, new Map());
  }
  leave(label: string): void { this.connected.delete(label); }
  rejoin(label: string): void {
    this.connected.add(label);
    const local = this.local.get(label);
    assert(local);
    this.published.set(label, structuredClone(local));
  }
  private mutate(label: string, edit: (state: Published) => void): void {
    const local = this.local.get(label);
    assert(local);
    edit(local);
    if (this.connected.has(label)) this.published.set(label, structuredClone(local));
  }
  setCursor(label: string, value: Cursor): void {
    this.mutate(label, state => { state.cursor = value; state.revision++; });
  }
  setItem(label: string, key: string, value: Item): void { this.mutate(label, state => { state.items.set(key, value); }); }
  deleteItem(label: string, key: string): void { this.mutate(label, state => { state.items.delete(key); }); }
  notify(sender: string, name: string, args: Json[]): void {
    for (const label of this.connected) {
      if (label === sender) continue;
      const bySender = this.received.get(label);
      assert(bySender);
      const list = bySender.get(sender) ?? [];
      list.push([name, args]);
      bySender.set(sender, list);
    }
  }
  expected(observer: string): View {
    const local = this.local.get(observer);
    assert(local);
    const bySender = this.received.get(observer);
    assert(bySender);
    const others = this.joined.filter(label => label !== observer);
    return {
      attendees: byFirst(this.joined.map((label): [string, string] => [label, this.connected.has(label) ? 'Connected' : 'Disconnected'])),
      cursor: {
        local: { ...local.cursor },
        remotes: byFirst(others.map((label): [string, Json, number] => {
          const state = this.published.get(label);
          assert(state);
          return [label, { ...state.cursor }, state.revision];
        })),
      },
      items: {
        local: byFirst([...local.items].map(([key, item]): [string, Json] => [key, { ...item }])),
        remotes: byFirst(others.flatMap((label): [string, [string, Json][]][] => {
          const state = this.published.get(label);
          assert(state);
          const entries = byFirst([...state.items].map(([key, item]): [string, Json] => [key, { ...item }]));
          return entries.length > 0 ? [[label, entries]] : [];
        })),
      },
      notifications: Object.fromEntries(bySender),
    };
  }
}

// ---- Scenario ----

const plantDivergence = process.argv.includes('--plant-divergence');

async function scenario(seed: number): Promise<void> {
  const trace: unknown[] = [{ seed }];
  const swift = new Swift(trace);
  const containers: IContainer[] = [];
  const clients: Client[] = [];
  const model = new Model();
  const random = new Random(seed);
  try {
    const tinyClient = new TinyliciousClient({ connection: { port } });
    const created = await tinyClient.createContainer(schema, '2.0.0');
    const creatorFluid = created.container;
    assert(isInternalFluidContainer(creatorFluid));
    const creator = creatorFluid.container;
    containers.push(creator);
    const document = await creatorFluid.attach();
    await until(() => creator.connectionState === 2, 'creator connected');

    const ts0 = new TsClient('ts0', creator, creatorFluid);
    async function addTs(label: string): Promise<TsClient> {
      const container = await loadExistingContainer({ ...props(), request: { url: document } });
      containers.push(container);
      const fluid = await createFluidContainer<typeof schema>({ container });
      await until(() => container.connectionState === 2, `${label} connected`);
      return new TsClient(label, container, fluid);
    }
    async function addSwift(label: string): Promise<SwiftClient> {
      const client = new SwiftClient(label, swift, document);
      await client.open();
      return client;
    }
    async function join(client: Client): Promise<void> {
      await client.join();
      clients.push(client);
      model.join(client.label);
    }

    const labels = () => new Map(clients.map(client => [client.attendeeId, client.label]));
    async function checkpoint(name: string): Promise<void> {
      let last: unknown;
      try {
        await until(async () => {
          const failures: unknown[] = [];
          for (const client of clients.filter(c => c.connected)) {
            try {
              const view = normalize(await client.view(), labels());
              if (plantDivergence && client.kind === 'swift') view.cursor.local = { x: -1, y: seed };
              const expected = model.expected(client.label);
              trace.push({ checkpoint: name, client: client.label, view, expected });
              assert.deepEqual(view, expected, `${name}: ${client.label}`);
            } catch (error) {
              failures.push(error);
            }
          }
          last = failures[0];
          if (failures.length > 0) trace.push({ checkpointFailures: failures.map(String) });
          return failures.length === 0;
        }, name);
      } catch (error) {
        throw last ?? error;
      }
    }

    // A notification sent while a join response is queued is absorbed by it and never leaves (notifications
    // are not stored state, so the queued full send has none; presenceDatastoreManager.ts queuedData
    // `sendAll` dominates later partials). That is upstream behavior that the H9 farm pins. Settle
    // after a membership change: the slowest response is 200 + 40 * (3 * providers + order),
    // order being below ten for clients outside the quorum.
    async function settle(): Promise<void> {
      await sleep(1500);
    }

    let count = 0;
    async function randomOperations(total: number): Promise<void> {
      for (let index = 0; index < total; index++) {
        const client = random.pick(clients.filter(c => c.connected));
        const kind = random.int(4);
        const label = client.label;
        if (kind === 0) {
          const value = { x: random.int(100), y: ++count };
          model.setCursor(label, value);
          await client.setCursor(value);
        } else if (kind === 1) {
          const key = `k${random.int(4)}`;
          const value = { n: ++count };
          model.setItem(label, key, value);
          await client.setItem(key, value);
        } else if (kind === 2) {
          const local = model.local.get(label);
          assert(local);
          const keys = [...local.items.keys()];
          if (keys.length === 0) continue;
          const key = random.pick(keys);
          model.deleteItem(label, key);
          await client.deleteItem(key);
        } else {
          const tag = [`s${seed}`, `${random.int(10)}`];
          ++count;
          model.notify(label, 'ping', [label, count, tag]);
          await client.notify(label, count, tag);
        }
      }
    }

    await join(ts0);
    const swift0 = await addSwift('swift0');
    await join(swift0);
    await checkpoint('both joined');
    await settle();

    await randomOperations(8 + random.int(6));
    await checkpoint('first edits');

    // Late joiners learn existing state from join responses, which each side must accept from the other.
    const lateTs = await addTs('ts1');
    const lateSwift = await addSwift('swift1');
    const late = random.int(2) === 0 ? [lateTs, lateSwift] : [lateSwift, lateTs];
    for (const client of late) await join(client);
    await checkpoint('late joiners');
    await settle();

    await randomOperations(8 + random.int(6));
    await checkpoint('all editing');

    // Leaving is audience removal; state stays. Offline edits stay local until the rejoin publishes them.
    await lateTs.disconnect();
    model.leave('ts1');
    await swift0.disconnect();
    model.leave('swift0');
    await checkpoint('two left');
    for (const client of [lateTs, swift0]) {
      const value = { x: random.int(100), y: ++count };
      model.setCursor(client.label, value);
      await client.setCursor(value);
      const item = { n: ++count };
      model.setItem(client.label, 'offline', item);
      await client.setItem('offline', item);
    }
    await randomOperations(4);
    await checkpoint('offline edits unpublished');

    await swift0.reconnect();
    model.rejoin('swift0');
    await lateTs.reconnect();
    model.rejoin('ts1');
    await checkpoint('both rejoined');
    await settle();

    await randomOperations(8 + random.int(6));
    await checkpoint('final');

    // Signals both sides received are byte-identical, and the Swift signals are well-formed presence
    // messages on the extension address.
    for (const client of clients) {
      if (!(client instanceof SwiftClient)) continue;
      const received = (await client.sessionView()).signals.map(signal => JSON.stringify(signal));
      const tsSignals = new Set(ts0.signals);
      let sent = 0;
      for (const text of received) {
        const signal = z.object({ clientId: z.string().nullable(), content: z.string() }).parse(JSON.parse(text));
        if (signal.clientId === null) continue;
        assert(tsSignals.has(text), `${client.label}: signal not seen identically by TS: ${text}`);
        if (!client.clientIds.has(signal.clientId)) continue;
        const envelope = z.object({
          address: z.string(),
          contents: z.object({ type: z.string() }),
        }).parse(JSON.parse(signal.content));
        assert.equal(envelope.address, extensionAddress);
        assert(presenceMessageTypes.includes(envelope.contents.type), `unexpected presence message ${envelope.contents.type}`);
        sent++;
      }
      assert(sent > 0, `${client.label} sent no presence signals`);
    }

    // The comparator rejects a planted extra attendee and a planted value.
    const swiftView = normalize(await swift0.view(), labels());
    const expected = model.expected('swift0');
    assert.deepEqual(swiftView, expected);
    assert.throws(() => assert.deepEqual({ ...swiftView, cursor: { ...swiftView.cursor, local: { x: -1, y: seed } } }, expected));
    assert.throws(() => assert.deepEqual({ ...swiftView, attendees: [...swiftView.attendees, ['planted', 'Connected']] }, expected));
    console.log(`service:presence seed ${seed}: passed (planted divergence caught)`);
  } catch (error) {
    trace.push({ failure: String(error) });
    await mkdir(resolve(root, 'harness/traces'), { recursive: true });
    await writeFile(resolve(root, `harness/traces/service-presence-${seed}.jsonl`), trace.map(entry => JSON.stringify(entry)).join('\n') + '\n');
    throw error;
  } finally {
    for (const container of containers) container.dispose();
    await swift.close();
  }
}

const temporary = await mkdtemp(join(tmpdir(), 'fluid-service-presence-'));
const tiny = spawn(process.execPath, [resolve(root, 'harness/node_modules/tinylicious/dist/index.js')], {
  cwd: temporary,
  env: { ...process.env, PORT: String(port), storage: join(temporary, 'storage') },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let logs = '';
tiny.stdout.on('data', (chunk: Buffer) => { logs += chunk.toString(); });
tiny.stderr.on('data', (chunk: Buffer) => { logs += chunk.toString(); });
let failed = false;
try {
  await until(async () => {
    if (tiny.exitCode !== null) throw new Error(logs);
    try { return (await fetch(endpoint)).ok; }
    catch { return false; }
  }, `tinylicious ${port} startup`);
  const seedIndex = process.argv.indexOf('--seeds');
  const range = seedIndex < 0 ? '0..4' : process.argv[seedIndex + 1];
  assert(range);
  const match = /^(\d+)\.\.(\d+)$/.exec(range);
  assert(match?.[1] && match[2], 'expected --seeds 0..N');
  for (let seed = Number(match[1]); seed <= Number(match[2]); seed++) await scenario(seed);
} catch (error) {
  failed = true;
  console.error(logs.slice(-3000));
  console.error(error);
} finally {
  const exited = once(tiny, 'exit');
  tiny.kill();
  await exited;
  await rm(temporary, { recursive: true, force: true });
}
// TS containers leave timers alive after disposal; all owned resources are closed.
process.exit(failed ? 1 : 0);
