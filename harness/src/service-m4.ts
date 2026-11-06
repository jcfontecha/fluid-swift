// M4: live co-editing against the local ODSP service (harness/src/odsp-service). Real 3.11.0
// `OdspClient` peers (and, with `--clients ...,swift`, the Swift M4 peer) open one SharePoint
// Embedded file, edit a SharedMap and a SharedString under lag, reconnects and push faults,
// publish presence signals, share attachment blobs, and let the TS summarizer run. Every
// checkpoint requires equal sequence numbers, equal state, no pending ops, no server failures and
// no driver error/retry telemetry; fresh clients must load an acked summary and match live state.
// See harness/PROTOCOL.md "M4 — ODSP live service".
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { MessageType } from '@fluidframework/driver-definitions/internal';
import { Random } from './random.js';
import { OdspLocalService } from './odsp-service/server.js';
import { dumpFile } from './odsp-service/store.js';
import { m4Client, m4Schema, type PeerEvent } from './odsp-service/m4-client.js';

const root = resolve(import.meta.dirname, '../..');
const swiftProduct = 'FluidOdspServicePeer';

function option(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index < 0 ? undefined : process.argv[index + 1];
}

const port = z.coerce.number().int().min(7095).max(7099).parse(option('--port') ?? '7095');

const kinds = z.array(z.enum(['ts', 'swift'])).min(2).max(4).parse((option('--clients') ?? 'ts,ts').split(','));
const seedRange = /^(\d+)\.\.(\d+)$/.exec(option('--seeds') ?? '0..9');
assert(seedRange?.[1] !== undefined && seedRange[2] !== undefined, 'expected --seeds A..B');
const firstSeed = Number(seedRange[1]);
const lastSeed = Number(seedRange[2]);
const parallel = z.coerce.number().int().min(1).parse(option('--parallel') ?? '1');
const plantDivergence = process.argv.includes('--plant-divergence');
const scratchPath = option('--scratch-path') ?? '.build/m4';

const eventSchema = z.object({ eventName: z.string(), category: z.string(), detail: z.string() });
const viewSchema = z.object({
  connected: z.boolean(),
  clientId: z.string().nullable(),
  sequenceNumber: z.number().int(),
  initialSequenceNumber: z.number().int(),
  pending: z.boolean(),
  map: z.record(z.string(), z.unknown()),
  text: z.string(),
});
type View = z.infer<typeof viewSchema>;
const presenceSchema = z.object({
  attendee: z.string(),
  remotes: z.array(z.object({ attendee: z.string(), connected: z.boolean(), value: z.unknown() })),
});
const rpcSchema = z.object({
  id: z.number(),
  result: z.unknown().optional(),
  error: z.object({ message: z.string() }).optional(),
});

const sleep = (ms: number) => new Promise<void>(done => setTimeout(done, ms));

/** Peer processes that exited while the run still needed them. */
const peerExits: string[] = [];

/** Polls `test`; a server failure or a peer exit ends the wait immediately instead of timing out. */
async function until(test: () => boolean | Promise<boolean>, label: string, failures: readonly string[], timeoutMs = 60000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    assert.deepEqual(failures, [], `${label}: server failures`);
    assert.deepEqual(peerExits, [], `${label}: peer exits`);
    if (await test()) {
      return;
    }
    await sleep(25);
  }
  throw new Error(`Timeout: ${label}`);
}

/**
 * One peer process (TS or Swift) speaking the M4 stdio JSON-RPC interface. Requests are
 * serialized per process: each waits for the previous response.
 */
class Peer {
  readonly child;
  private readonly lines;
  private id = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private closing = false;

  constructor(readonly kind: 'ts' | 'swift', readonly index: number, seed: number) {
    const command = kind === 'ts' ? process.execPath : resolve(root, scratchPath, 'debug', swiftProduct);
    const args = kind === 'ts' ? [resolve(root, 'harness/node_modules/tsx/dist/cli.mjs'), resolve(root, 'harness/src/odsp-service/ts-peer.ts')] : [];
    this.child = spawn(command, args, { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stderr.on('data', (chunk: Buffer) => process.stderr.write(`[seed ${seed} peer ${index} ${kind}] ${chunk.toString()}`));
    this.lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
    this.child.on('exit', code => {
      if (!this.closing) {
        peerExits.push(`seed ${seed} peer ${index} (${kind}) exited with code ${code}`);
      }
    });
  }

  call(method: string, params: Record<string, unknown>, trace: unknown[]): Promise<unknown> {
    const next = this.queue.then(() => this.send(method, params, trace));
    this.queue = next.catch(() => undefined);
    return next;
  }

  private async send(method: string, params: Record<string, unknown>, trace: unknown[]): Promise<unknown> {
    const request = { jsonrpc: '2.0', id: ++this.id, method, params };
    trace.push({ peer: this.index, request });
    this.child.stdin.write(JSON.stringify(request) + '\n');
    let timer: NodeJS.Timeout | undefined;
    const line = await Promise.race([
      this.lines.next(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`peer ${this.index} RPC timeout: ${method}`)), 60000);
      }),
    ]).finally(() => clearTimeout(timer));
    assert(line.done !== true, `peer ${this.index} exited`);
    const response = rpcSchema.parse(JSON.parse(line.value));
    assert.equal(response.id, this.id);
    if (response.error !== undefined) {
      trace.push({ peer: this.index, error: response.error });
      throw new Error(`peer ${this.index} ${method}: ${response.error.message}`);
    }
    trace.push({ peer: this.index, result: response.result });
    return response.result;
  }

  async close(): Promise<void> {
    this.closing = true;
    if (this.child.exitCode === null) {
      const exited = once(this.child, 'exit');
      this.child.stdin.end();
      await exited;
    }
  }
}

/** A client handle open on one peer; every request and response lands in its seed's trace. */
class Client {
  constructor(
    readonly peer: Peer,
    readonly name: string,
    private readonly trace: unknown[],
  ) {}

  call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    return this.peer.call(method, { client: this.name, ...params }, this.trace);
  }

  async view(): Promise<View> {
    return viewSchema.parse(await this.call('view'));
  }

  async presence(): Promise<z.infer<typeof presenceSchema>> {
    return presenceSchema.parse(await this.call('presence'));
  }

  private reported = 0;

  /** Telemetry events reported since the previous call. */
  async newEvents(): Promise<PeerEvent[]> {
    const events = z.array(eventSchema).parse(await this.call('events'));
    const fresh = events.slice(this.reported);
    this.reported = events.length;
    return fresh;
  }
}

/**
 * The one telemetry error an injected disconnect may cause: presence sending a queued signal in the
 * window where the container runtime still reports a connection but the ConnectionManager has
 * already dropped it (container-loader connectionManager.ts submitSignal).
 */
const faultEvent = /:ConnectionManager:submitSignalDisconnected$/;

const words = ['alpha', 'βeta', 'gamma ', '🙂', 'δ', 'x', 'line\n', 'zz'];

type Channel = 'map' | 'text';

/** One random edit of an unfrozen channel; text positions are clamped by the peer. */
async function edit(random: Random, client: Client, seed: number, step: number, frozen: Channel | undefined): Promise<void> {
  const choice = frozen === 'map' ? 5 + random.int(5) : frozen === 'text' ? random.int(5) : random.int(10);
  if (choice < 4) {
    await client.call('mapSet', { key: `k${random.int(12)}`, value: { seed, step, by: client.name, nested: [random.int(1000), null, 'ü'] } });
    return;
  }
  if (choice < 5) {
    await client.call('mapDelete', { key: `k${random.int(12)}` });
    return;
  }
  if (choice < 8) {
    await client.call('textInsert', { pos: random.int(60), text: random.pick(words) });
    return;
  }
  const start = random.int(60);
  await client.call('textRemove', { start, end: start + 1 + random.int(6) });
}

/** Last sequenced runtime op ("op" type): summaries at or after it contain the final state. */
function lastRuntimeOp(service: OdspLocalService, itemId: string): number {
  const ops = service.file(itemId).ops;
  for (let index = ops.length - 1; index >= 0; index--) {
    const op = ops[index];
    if (op !== undefined && op.type === MessageType.Operation) {
      return op.sequenceNumber;
    }
  }
  return 0;
}

async function scenario(seed: number, service: OdspLocalService): Promise<void> {
  const random = new Random(seed);
  // Each seed has its own peer processes: a seed's clients share their processes' push sockets, but
  // no other seed's connections do (see OdspPush.serverDisconnect for why that matters).
  const peers = kinds.map((kind, index) => new Peer(kind, index, seed));
  const trace: unknown[] = [{ seed, clients: kinds }];
  const info = service.connectionInfo();
  const editors: Client[] = [];
  const failures = service.failures;
  let itemId: string | undefined;
  try {
    /** Attachment blobs uploaded so far: map key to UTF-8 text. */
    const blobs = new Map<string, string>();
    // Create in TS (the Swift peer opens existing files), exactly as an app attaches a new container.
    // A blob uploaded while detached makes the driver create an empty file, upload the blob, upload
    // the first summary without a parent and rename the file (createFile.ts); otherwise the file is
    // created from the summary in one request.
    const creatorEvents: PeerEvent[] = [];
    const created = await m4Client(info.siteUrl, info.driveId, `creator${seed}`, creatorEvents).createContainer(m4Schema, '2.0.0');
    created.container.initialObjects.map.set('created', { seed });
    created.container.initialObjects.text.insertText(0, `seed ${seed}: `);
    if (random.int(2) === 0) {
      const text = `seed ${seed} detached blob`;
      const handle = await created.container.uploadBlob(new TextEncoder().encode(text).buffer);
      created.container.initialObjects.map.set('blob-detached', handle);
      blobs.set('blob-detached', text);
    }
    const fileId = await created.container.attach();
    itemId = fileId;
    trace.push({ itemId: fileId });
    await until(() => created.container.connectionState === 2 && !created.container.isDirty, 'creator attached and saved', failures);
    created.container.dispose();
    assert.deepEqual(creatorEvents, [], 'creator telemetry');
    const file = service.file(fileId);
    const open = async (peer: Peer, name: string, user: string): Promise<Client> => {
      const client = new Client(peer, name, trace);
      await client.call('open', { siteUrl: info.siteUrl, driveId: info.driveId, itemId: fileId, user });
      return client;
    };

    for (const [index, peer] of peers.entries()) {
      editors.push(await open(peer, `s${seed}-c${index}`, `user${index}`));
    }

    /** `faulted` clients were disconnected by this phase's fault and may report `faultEvent`. */
    const checkpoint = async (label: string, extra: Client[] = [], faulted: Client[] = []): Promise<View[]> => {
      const all = [...editors, ...extra];
      let views: View[] = [];
      await until(async () => {
        views = [];
        for (const client of all) {
          views.push(await client.view());
        }
        const target = file.lastPersistedSequenceNumber;
        return views.every(view => view.connected && !view.pending && view.sequenceNumber === target);
      }, `${label}: quiescent at ${file.lastPersistedSequenceNumber}`, failures);
      const expected = views[0];
      assert(expected !== undefined);
      for (const [index, view] of views.entries()) {
        const observed = plantDivergence && index === views.length - 1 ? { ...view.map, 'planted-divergence': seed } : view.map;
        trace.push({ label, client: all[index]?.name, view });
        assert.deepEqual(observed, expected.map, `${label}: map of ${all[index]?.name}`);
        assert.equal(view.text, expected.text, `${label}: text of ${all[index]?.name}`);
      }
      for (const client of all) {
        for (const [key, text] of blobs) {
          assert.equal(z.string().parse(await client.call('blobRead', { key })), text, `${label}: blob ${key} on ${client.name}`);
        }
      }
      assert.deepEqual(failures, [], `${label}: server failures`);
      for (const client of all) {
        const events = await client.newEvents();
        const unexpected = faulted.includes(client) ? events.filter(event => !faultEvent.test(event.eventName)) : events;
        assert.deepEqual(unexpected, [], `${label}: telemetry of ${client.name}`);
      }
      return views;
    };

    /**
     * After the first summary one channel stops changing, so every later summary must reuse it
     * from its parent by handle; a wrong handle resolution then shows up in fresh-load state.
     */
    let frozen: Channel | undefined;
    const round = async (rounds: number, active: Client[]) => {
      for (let step = 0; step < rounds; step++) {
        for (const client of active) {
          const count = 1 + random.int(3);
          for (let index = 0; index < count; index++) {
            await edit(random, client, seed, step, frozen);
          }
        }
        await sleep(random.int(15));
      }
    };

    /** Every editor publishes a presence value and must observe every other editor's value. */
    const presenceRound = async (label: string, generation: number) => {
      const expected = new Map<string, unknown>();
      for (const client of editors) {
        const value = { by: client.name, n: generation * 1000 + random.int(1000) };
        await client.call('presenceSet', { value });
        expected.set((await client.presence()).attendee, value);
      }
      await until(async () => {
        for (const client of editors) {
          const view = await client.presence();
          for (const [attendee, value] of expected) {
            if (attendee === view.attendee) {
              continue;
            }
            const remote = view.remotes.find(entry => entry.attendee === attendee);
            if (remote === undefined || !remote.connected || JSON.stringify(remote.value) !== JSON.stringify(value)) {
              return false;
            }
          }
        }
        return true;
      }, `${label}: presence values delivered`, failures);
    };

    /** Waits until an acked summary covers every runtime op sequenced so far. */
    const summarized = async (label: string): Promise<number> => {
      const covered = lastRuntimeOp(service, fileId);
      await until(() => (file.latest?.sequenceNumber ?? 0) >= covered, `${label}: summary covering op ${covered}`, failures, 90000);
      return covered;
    };

    /** Opens a fresh client (new OdspClient, no caches) and checks it loaded a committed snapshot. */
    const freshLoad = async (name: string, atLeast: number): Promise<Client> => {
      const client = await open(random.pick(peers), name, name);
      const view = await client.view();
      assert(view.initialSequenceNumber >= atLeast, `${name} loaded from ${view.initialSequenceNumber} < ${atLeast}`);
      const committed = [...file.snapshots.values()].some(snapshot => snapshot.sequenceNumber === view.initialSequenceNumber);
      assert(committed, `${name} did not load a committed snapshot (${view.initialSequenceNumber})`);
      return client;
    };

    await until(async () => {
      for (const client of editors) {
        if (!(await client.view()).connected) {
          return false;
        }
      }
      return true;
    }, 'all peers connected', failures);
    await checkpoint('open');

    await round(6 + random.int(6), editors);
    await presenceRound('presence', 1);
    await checkpoint('concurrent');

    // Attachment blobs: upload from one client, read through handles on every client.
    for (let index = 0; index < 1 + random.int(2); index++) {
      const uploader = random.pick(editors);
      const key = `blob-${index}`;
      const text = `seed ${seed} blob ${index} ${'🙂'.repeat(random.int(40))}`;
      await uploader.call('blobUpload', { key, text });
      blobs.set(key, text);
    }
    await round(2, editors);
    await checkpoint('attachments');

    // First summary by the elected TS summarizer; later summaries reuse its subtrees by handle.
    const firstCovered = await summarized('first summary');
    frozen = random.pick<Channel>(['map', 'text']);
    const handlesBefore = file.handleReferences;

    // Lagging: one client stops processing inbound ops while everyone (including it) edits.
    const laggard = random.pick(editors);
    await laggard.call('pauseInbound');
    await round(4 + random.int(4), editors);
    await sleep(100 + random.int(300));
    await laggard.call('resumeInbound');
    await checkpoint('lagging');

    // Reconnect: offline edits are resubmitted after reconnecting.
    const offline = random.pick(editors);
    await offline.call('disconnect');
    await round(3 + random.int(4), editors);
    await offline.call('connect');
    await round(2, editors);
    await checkpoint('reconnect', [], [offline]);

    // Push faults: server_disconnect for one client (injected once no handshake is in flight on its
    // socket, see OdspPush.serverDisconnect), then deli dropping another (its next op is nacked).
    const dropped = random.pick(editors);
    const droppedId = (await dropped.view()).clientId;
    assert(droppedId !== null);
    const code = random.pick([401, 503]);
    await until(() => service.push.serverDisconnect(droppedId, code), 'server_disconnect on a socket without handshakes', failures);
    await round(2 + random.int(3), editors);
    await checkpoint('server_disconnect', [], [dropped]);
    assert.notEqual((await dropped.view()).clientId, droppedId, 'server_disconnect forced a new connection');
    const evicted = random.pick(editors);
    const evictedId = (await evicted.view()).clientId;
    assert(evictedId !== null);
    service.push.evict(evictedId);
    await round(2 + random.int(3), [evicted]);
    await round(2, editors);
    await checkpoint('evicted', [], [evicted]);
    assert.notEqual((await evicted.view()).clientId, evictedId, 'the nack forced a new connection');
    await presenceRound('presence after faults', 2);

    // Mid-stream fresh load: a committed snapshot plus trailing ops from snapshot and opStream.
    const mid = await freshLoad(`s${seed}-mid`, firstCovered);
    await round(2, [...editors, mid]);
    await checkpoint('mid-stream load', [mid]);
    await mid.call('close');

    // Final summary: a fresh client loads a summary with no runtime ops after it, so its
    // state is the summary's alone, and must equal live state.
    const finalCovered = await summarized('final summary');
    assert(file.snapshots.size >= 3, 'the TS summarizer produced at least two acked summaries');
    assert(file.handleReferences > handlesBefore, `summaries after the first reused the frozen ${frozen} by handle`);
    const final = await freshLoad(`s${seed}-final`, finalCovered);
    await checkpoint('summary load', [final]);
    await final.call('close');

    // The comparator must reject a planted divergence on every seed.
    const views = await checkpoint('final');
    const first = views[0];
    assert(first !== undefined);
    assert.throws(() => assert.deepEqual({ ...first.map, 'planted-divergence': seed }, first.map));
    console.log(`service:m4 seed ${seed} [${kinds.join(',')}]: passed (ops ${file.ops.length}, summaries ${file.snapshots.size - 1}, frozen ${frozen}, planted divergence caught)`);
  } catch (error) {
    trace.push({ failure: String(error), failures: [...failures], rest: service.rest.records.filter(record => record.status >= 400) });
    await mkdir(resolve(root, 'harness/traces'), { recursive: true });
    const name = `harness/traces/service-m4-${kinds.join('-')}-${seed}`;
    await writeFile(resolve(root, `${name}.jsonl`), trace.map(entry => JSON.stringify(entry)).join('\n') + '\n');
    if (itemId !== undefined) {
      // The service's storage for the file, for `tsx src/odsp-service/replay.ts <dump>`.
      await writeFile(resolve(root, `${name}.odsp.json`), JSON.stringify(dumpFile(service.file(itemId))));
    }
    throw error;
  } finally {
    for (const client of editors) {
      await client.call('close').catch(() => undefined);
    }
    for (const peer of peers) {
      await peer.close();
    }
  }
}

/** REST routes with ids replaced by placeholders. */
function routeName(route: string, driveId: string): string {
  return route
    .replace(driveId, '{drive}')
    .replace(/\/items\/root:[^:]*:\//, '/items/root:{path}:/')
    .replace(/\/items\/[0-9A-Z]{34}/, '/items/{item}')
    .replace(/\/attachments\/[^/]+\//, '/attachments/{id}/');
}

/** The ODSP surface every run must exercise; anything missing means the scenario lost coverage. */
const requiredSurface = [
  'POST /_api/v2.1/drives/{drive}/items/root:{path}:/opStream/snapshots/snapshot',
  'PUT /_api/v2.1/drives/{drive}/items/root:{path}:/content',
  'PATCH /_api/v2.1/drives/{drive}/items/{item}',
  'POST /_api/v2.1/drives/{drive}/items/{item}/opStream/joinSession',
  'GET /_api/v2.1/drives/{drive}/items/{item}/opStream/snapshots/trees/latest',
  'GET /_api/v2.1/drives/{drive}/items/{item}/opStream',
  'POST /_api/v2.1/drives/{drive}/items/{item}/opStream/snapshots/snapshot',
  'POST /_api/v2.1/drives/{drive}/items/{item}/opStream/attachment/content',
  'GET /_api/v2.1/drives/{drive}/items/{item}/opStream/attachments/{id}/content',
  'connect_document',
  'submitOp',
  'submitSignal',
  'get_ops',
  'flush_ops',
  'disconnect_document',
  'emit nack',
  'summary handle reference',
];

if (kinds.includes('swift')) {
  // Fail loudly when the Swift M4 peer cannot be built: no silent fallback to TS.
  try {
    execFileSync('swift', ['build', '--scratch-path', scratchPath, '--product', swiftProduct], { cwd: root, stdio: 'inherit' });
  } catch (error) {
    throw new Error(`--clients includes swift but the Swift M4 peer (${swiftProduct}) could not be built: ${String(error)}`);
  }
  assert(existsSync(resolve(root, scratchPath, 'debug', swiftProduct)), `${swiftProduct} binary missing after build`);
}

const service = await OdspLocalService.start(port);
try {
  const seeds: number[] = [];
  for (let seed = firstSeed; seed <= lastSeed; seed++) {
    seeds.push(seed);
  }
  // `--parallel N` runs N seeds at a time, each with its own file and its own peer processes.
  const workers = Array.from({ length: Math.min(parallel, seeds.length) }, async () => {
    for (let seed = seeds.shift(); seed !== undefined; seed = seeds.shift()) {
      await scenario(seed, service);
    }
  });
  await Promise.all(workers);
  const surface = new Map<string, number>();
  for (const record of service.rest.records) {
    const name = routeName(record.route, service.drive.driveId);
    surface.set(name, (surface.get(name) ?? 0) + 1);
  }
  for (const [event, count] of service.push.counts) {
    surface.set(event, count);
  }
  let handleReferences = 0;
  for (const file of service.drive.files.values()) {
    handleReferences += file.handleReferences;
  }
  surface.set('summary handle reference', handleReferences);
  console.log(`service:m4 surface: ${JSON.stringify(Object.fromEntries(surface))}`);
  for (const name of requiredSurface) {
    assert((surface.get(name) ?? 0) > 0, `ODSP surface not exercised: ${name}`);
  }
} finally {
  await service.close();
}
// The TS summarizer leaves race timers alive after disposal; all owned resources are closed.
process.exit(0);
