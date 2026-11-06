import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { loadExistingContainer, loadSummarizerContainerAndMakeSummary } from '@fluidframework/container-loader/internal';
import { isIDeltaManagerFull } from '@fluidframework/container-definitions/internal';
import type { IContainer } from '@fluidframework/container-definitions/internal';
import { createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { SharedMap } from 'fluid-framework/legacy';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { isInternalFluidContainer } from '@fluidframework/fluid-static/internal';
import { RouterliciousDocumentServiceFactory } from '@fluidframework/routerlicious-driver/internal';
import { InsecureTinyliciousTokenProvider, InsecureTinyliciousUrlResolver } from '@fluidframework/tinylicious-driver/internal';
import { isFluidHandle, toFluidHandleInternal } from '@fluidframework/runtime-utils/internal';
import { ContainerRuntime } from '@fluidframework/container-runtime/internal';
import { SummarizerNodeWithGC } from '../node_modules/@fluidframework/container-runtime/lib/summary/summarizerNode/summarizerNodeWithGc.js';
import { wholeUpload } from './service-m3-upload.js';
import { modelScenario } from './service-m3-model.js';
import { Random } from './random.js';

const root = resolve(import.meta.dirname, '../..');
const endpoint = 'http://localhost:7075';
const scratchPath = process.argv.find(arg => arg.startsWith('--scratch-path='))?.slice('--scratch-path='.length) ?? '.build/m3b';
execFileSync('swift', ['build', '--scratch-path', scratchPath, '--product', 'FluidServicePeer'], { cwd: root, stdio: 'inherit' });
const objectSchema = z.record(z.string(), z.unknown());
const opSchema = objectSchema.and(z.object({ sequenceNumber: z.number() }));
const runtimeSchema = z.object({
  referenceSequenceNumber: z.number(),
  pendingMessages: z.number(),
  datastores: z.array(z.object({ id: z.string(), channels: z.array(z.string()), pendingOps: z.number() })),
});
const viewSchema = z.object({
  runtime: runtimeSchema,
  sequenceNumber: z.number(),
  snapshotSequenceNumber: z.number(),
  ops: z.array(opSchema),
  opSources: z.array(z.enum(['storage', 'socket'])),
  connected: z.boolean(),
});
const rpcSchema = z.object({
  id: z.number(),
  result: z.unknown().optional(),
  error: z.object({ message: z.string() }).optional(),
});
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function until(test: () => boolean | Promise<boolean>, label: string): Promise<void> {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await test()) return;
    await sleep(20);
  }
  throw new Error(`Timeout: ${label}`);
}
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
  async view(client: string) {
    return viewSchema.parse(await this.call('view', client));
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
const tsRuntimes: ContainerRuntime[] = [];
function props() {
  return {
    urlResolver: new InsecureTinyliciousUrlResolver({ port: 7075 }),
    documentServiceFactory: new RouterliciousDocumentServiceFactory(new InsecureTinyliciousTokenProvider()),
    codeLoader: {
      load: async () => ({
        module: {
          fluidExport: runtimeFactory(),
        },
        details: { package: 'service-map' },
      }),
    },
    clientDetailsOverride: { capabilities: { interactive: true } },
    configProvider: { getRawConfig: (name: string) => name === 'Fluid.Container.ForceWriteConnection' ? true : undefined },
  };
}
function runtimeFactory() {
  const factory = createDOProviderContainerRuntimeFactory({
            schema,
            oldestSupportedClient: '2.0.0',
            runtimeOptionOverrides: {
              summaryOptions: {
                summaryConfigOverrides: {
                  state: 'disableHeuristics',
                  initialSummarizerDelayMs: 0,
                  maxAckWaitTime: 20000,
                  maxOpsSinceLastSummary: 7000,
                },
              },
            },
          });
  const instantiate = factory.instantiateRuntime.bind(factory);
  factory.instantiateRuntime = async (context, existing) => {
    const runtime = await instantiate(context, existing);
    assert(runtime instanceof ContainerRuntime);
    tsRuntimes.push(runtime);
    return runtime;
  };
  return factory;
}
function mapState(map: { entries(): IterableIterator<[string, unknown]> }): unknown {
  return JSON.parse(JSON.stringify(Object.fromEntries(map.entries()), (_key: string, value: unknown) =>
    isFluidHandle(value) ? { type: '__fluid_handle__', url: toFluidHandleInternal(value).absolutePath } : value));
}
async function captureFixture(document: string, name: string): Promise<void> {
  if (!process.argv.includes('--capture-fixture')) return;
  const resolved = await props().urlResolver.resolve({ url: document });
  assert(resolved?.type === 'fluid');
  const service = await props().documentServiceFactory.createDocumentService(resolved);
  try {
    const storage = await service.connectToStorage();
    const snapshot = await storage.getSnapshotTree();
    assert(snapshot);
    type CapturedTree = { type: 1; tree: Record<string, CapturedTree | { type: 2; content: string }> };
    async function capture(tree: import('@fluidframework/driver-definitions/internal').ISnapshotTree): Promise<CapturedTree> {
      const result: CapturedTree = { type: 1, tree: {} };
      for (const [name, id] of Object.entries(tree.blobs)) {
        result.tree[name] = { type: 2, content: Buffer.from(await storage.readBlob(id)).toString('utf8') };
      }
      for (const [name, child] of Object.entries(tree.trees)) result.tree[name] = await capture(child);
      return result;
    }
    const captured = await capture(snapshot);
    await mkdir(resolve(root, 'Tests/FluidContainerLoaderTests/Fixtures'), { recursive: true });
    await writeFile(resolve(root, `Tests/FluidContainerLoaderTests/Fixtures/${name}.json`), JSON.stringify(captured));
  } finally {
    service.dispose();
  }
}
async function scenario(seed: number) {
  const trace: unknown[] = [{ seed }];
  const swift = new Swift(trace);
  const containers: IContainer[] = [];
  try {
    await wholeUpload(params => swift.call('uploadSummary', 'upload', params));
    const model = modelScenario(seed);
    assert.deepEqual(await swift.call('summaryTrace', 'model', { steps: model.steps }), model.expected, 'TS/Swift election and deterministic heuristic decisions');
    const client = new TinyliciousClient({ connection: { port: 7075 } });
    const created = await client.createContainer(schema, '2.0.0');
    const fluid = created.container;
    assert(isInternalFluidContainer(fluid));
    const creator = fluid.container;
    containers.push(creator);
    assert(isIDeltaManagerFull(creator.deltaManager));
    const observed = new Map<number, string>();
    creator.deltaManager.inbound.on('push', op => { observed.set(op.sequenceNumber, JSON.stringify(op)); });
    const document = await fluid.attach();
    await until(() => creator.connectionState === 2, 'creator connected');
    if (seed === 0) await captureFixture(document, 'm2-attach');
    await swift.call('openM2', 'start', { endpoint, document });
    await until(async () => (await swift.view('start')).connected, 'Swift join');
    assert.equal((await swift.view('start')).snapshotSequenceNumber, 0, 'start must load the attach summary');
    fluid.initialObjects.map.set('captured', { seed, nested: [null, true, 'hello'] });
    await until(() => !creator.isDirty, 'fixture edits saved');
    await swift.call('summarize', 'start');
    if (seed === 0) await captureFixture(document, 'm2-summary');
    const maps = [fluid.initialObjects.map];
    async function checkpoint(clients: string[], label: string) {
      const snapshots = new Map<string, z.infer<typeof viewSchema>>();
      let checkpointSequence = 0;
      await until(async () => {
        checkpointSequence = creator.deltaManager.lastSequenceNumber;
        for (const client of clients) {
          const view = await swift.view(client);
          snapshots.set(client, view);
          if (view.sequenceNumber !== checkpointSequence || view.runtime.pendingMessages !== 0) return false;
        }
        return containers.every(container => !container.isDirty && container.deltaManager.lastSequenceNumber === checkpointSequence);
      }, label);
      const expected = mapState(fluid.initialObjects.map);
      for (const map of maps) assert.deepEqual(mapState(map), expected, label);
      for (const client of clients) {
        const fullView = snapshots.get(client);
        assert(fullView);
        for (const [index, op] of fullView.ops.entries()) {
          if (op.type === 'op' && fullView.opSources[index] === 'socket') {
            assert.equal(JSON.stringify(op), observed.get(op.sequenceNumber), `${label}: TS/Swift raw op ${op.sequenceNumber}`);
          }
        }
        const state = fullView.runtime;
        const path = toFluidHandleInternal(fluid.initialObjects.map.handle).absolutePath.split('/');
        assert.deepEqual(state, {
          referenceSequenceNumber: checkpointSequence,
          pendingMessages: 0,
          datastores: [{ id: path[1], channels: [path[2], 'root'].sort(), pendingOps: 0 }],
        }, `${label}: runtime and datastore state`);
        const view = z.record(z.string(), z.unknown()).parse(await swift.call('mapView', client));
        if (process.argv.includes('--plant-divergence')) view['planted-divergence'] = seed;
        trace.push({ label, client, expected, view });
        assert.deepEqual(view, expected, `${label}: ${client}`);
      }
    }
    await checkpoint(['start'], 'snapshot load');
    const random = new Random(seed);
    for (let index = 0; index < 40; index++) {
      const key = `key-${random.int(8)}`;
      const op = index % 13 === 0 ? 'clear' : index % 5 === 0 ? 'delete' : 'set';
      const value = { seed, index, nested: [true, null, { text: '🙂', number: random.int(100) }] };
      if (op === 'clear') fluid.initialObjects.map.clear();
      else if (op === 'delete') fluid.initialObjects.map.delete(key);
      else fluid.initialObjects.map.set(key, value);
      await swift.call('mapEdit', 'start', { op, key: `swift-${key}`, value });
    }
    fluid.initialObjects.map.set('ts-handle', { nested: [fluid.initialObjects.map.handle] });
    await swift.call('mapEdit', 'start', { op: 'set', key: 'swift-handle', value: { nested: [{ type: '__fluid_handle__', url: toFluidHandleInternal(fluid.initialObjects.map.handle).absolutePath }] } });
    await until(() => !creator.isDirty, 'concurrent TS saved');
    await checkpoint(['start'], 'concurrent writes');
    const beforeSummary = creator.deltaManager.lastSequenceNumber;
    await swift.call('summarize', 'start');
    await swift.call('openM2', 'mid', { endpoint, document });
    await until(async () => (await swift.view('mid')).connected, 'mid join');
    assert((await swift.view('mid')).snapshotSequenceNumber >= beforeSummary, 'mid client loaded an older summary');
    await checkpoint(['start', 'mid'], 'mid-stream summary');
    const other = await loadExistingContainer({ ...props(), request: { url: document } });
    containers.push(other);
    const otherFluid = await createFluidContainer<typeof schema>({ container: other });
    maps.push(otherFluid.initialObjects.map);
    await until(() => other.connectionState === 2, 'other join');
    otherFluid.initialObjects.map.set('joined', seed);
    await checkpoint(['start', 'mid'], 'TS join');
    await swift.call('disconnect', 'start');
    await swift.call('mapEdit', 'start', { op: 'set', key: 'offline', value: { seed } });
    await swift.call('mapEdit', 'start', { op: 'delete', key: 'joined' });
    await swift.call('mapEdit', 'start', { op: 'set', key: 'offline-conflict', value: 'swift' });
    fluid.initialObjects.map.set('offline-conflict', 'ts');
    for (let index = 0; index < 65; index++) {
      fluid.initialObjects.map.set('offline-remote', { seed, index });
      await sleep(1);
    }
    await until(() => !creator.isDirty, 'offline remote saved');
    await swift.call('reconnect', 'start');
    await until(async () => (await swift.view('start')).connected, 'reconnect');
    await checkpoint(['start', 'mid'], 'offline resubmission');
    other.disconnect();
    containers.pop();
    maps.pop();
    await checkpoint(['start', 'mid'], 'TS leave');
    // A rejected proposal must not advance the committed storage version or runtime baseline.
    await swift.call('summarize', 'start');
    const summariesBeforeNack = (await swift.view('start')).ops.filter(op => op.type === 'summaryAck').length;
    await swift.call('submitSummary', 'start', { contents: JSON.stringify({ handle: 'invalid-summary', head: 'invalid-parent', message: 'intentional nack', parents: ['invalid-parent'] }) });
    await until(async () => (await swift.view('start')).ops.some(op => op.type === 'summaryNack'), 'server summaryNack');
    assert.equal((await swift.view('start')).ops.filter(op => op.type === 'summaryAck').length, summariesBeforeNack);
    await swift.call('summarize', 'start');
    await checkpoint(['start', 'mid'], 'summary after nack');

    // Hand over from the TS interactive parent to Swift, then let Swift's own clock start its child.
    await swift.call('stopSummarizer', 'start');
    creator.disconnect();
    await swift.call('enableSummaries', 'mid');
    const electionSchema = z.object({ clientId: z.string(), election: z.object({ electedClientId: z.string(), electedParentId: z.string() }) });
    await until(async () => {
      const raw = await swift.call('summarizerView', 'mid');
      if (raw === null || !viewSchema.parse(raw).connected) return false;
      const child = electionSchema.parse(raw);
      return child.clientId === child.election.electedClientId;
    }, 'Swift elected child');
    const parent = electionSchema.parse(await swift.call('view', 'mid'));
    assert.equal(parent.clientId, parent.election.electedParentId);
    for (let index = 0; index < 110; index++) {
      await swift.call('mapEdit', 'start', { op: 'set', key: 'automatic', value: index });
    }
    await until(async () => z.object({ summaryAckCount: z.number() }).parse(await swift.call('summarizerView', 'mid')).summaryAckCount > 0, 'automatic heuristic summary ack');
    await until(async () => (await swift.view('mid')).sequenceNumber === (await swift.view('start')).sequenceNumber && (await swift.view('start')).runtime.pendingMessages === 0, 'post-trigger edits sequenced');
    await swift.call('summarize', 'mid');
    const fresh = await loadExistingContainer({ ...props(), request: { url: document } });
    containers.push(fresh);
    const freshFluid = await createFluidContainer<typeof schema>({ container: fresh });
    assert.deepEqual(mapState(freshFluid.initialObjects.map), await swift.call('mapView', 'start'), 'fresh TS loads automatic Swift summary');
    const tsRuntime = tsRuntimes.at(-1);
    assert(tsRuntime);
    await swift.call('openM2', 'comparison', { endpoint, document });
    await until(async () => fresh.deltaManager.lastSequenceNumber === (await swift.view('comparison')).sequenceNumber, 'same stream for summary comparison');
    const node: unknown = Reflect.get(tsRuntime, 'summarizerNode');
    assert(node instanceof SummarizerNodeWithGC);
    node.startSummary(fresh.deltaManager.lastSequenceNumber, { send() {} }, 0);
    const tsGenerated = await tsRuntime.summarize({ fullTree: true, trackState: false });
    node.clearSummary();
    const swiftGenerated = await swift.call('generateSummary', 'comparison');
    assert.deepEqual(swiftGenerated, tsGenerated.summary, 'byte-exact TS/Swift live summary tree and blob strings');
    await swift.call('disconnect', 'comparison');
    let finalAcks = 0;
    fresh.deltaManager.on('op', op => { if (op.type === 'summaryAck') finalAcks++; });
    for (let index = 0; index < 10; index++) {
      await swift.call('mapEdit', 'mid', { op: 'set', key: 'final-at-stop', value: index });
    }
    await until(async () => (await swift.view('mid')).runtime.pendingMessages === 0 &&
      (await swift.view('mid')).sequenceNumber === (await swift.view('start')).sequenceNumber &&
      freshFluid.initialObjects.map.get('final-at-stop') === 9, 'last-summary edits sequenced');
    await swift.call('disconnect', 'mid');
    await until(() => finalAcks > 0, 'graceful stop final summary ack');
    await swift.call('disconnect', 'start');
    await until(() => fresh.connectionState === 2, 'TS successor connected');
    const tsSummary = await loadSummarizerContainerAndMakeSummary({ ...props(), request: { url: document } });
    assert(tsSummary.success, 'TS summarizes after Swift departure');
    const actual = z.record(z.string(), z.unknown()).parse(await swift.call('mapView', 'start'));
    actual['planted-divergence'] = seed;
    assert.throws(() => assert.deepEqual(actual, mapState(freshFluid.initialObjects.map)));
    console.log(`service:m3 seed ${seed}: passed (planted divergence caught)`);
  } catch (error) {
    trace.push({ failure: String(error) });
    await mkdir(resolve(root, 'harness/traces'), { recursive: true });
    await writeFile(resolve(root, `harness/traces/service-m3-${seed}.jsonl`), trace.map(entry => JSON.stringify(entry)).join('\n') + '\n');
    throw error;
  } finally {
    for (const container of containers) container.dispose();
    await swift.close();
  }
}
const temporary = await mkdtemp(join(tmpdir(), 'fluid-service-m3-'));
const tiny = spawn(process.execPath, [resolve(root, 'harness/node_modules/tinylicious/dist/index.js')], {
  cwd: temporary,
  env: { ...process.env, PORT: '7075', storage: join(temporary, 'storage') },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let logs = '';
tiny.stdout.on('data', (chunk: Buffer) => { logs += chunk.toString(); });
tiny.stderr.on('data', (chunk: Buffer) => { logs += chunk.toString(); });
try {
  await until(async () => {
    if (tiny.exitCode !== null) throw new Error(logs);
    try { return (await fetch(endpoint)).ok; }
    catch { return false; }
  }, 'tinylicious 7075 startup');
  const seedIndex = process.argv.indexOf('--seeds');
  const range = seedIndex < 0 ? '0..9' : process.argv[seedIndex + 1];
  assert(range);
  const match = /^(\d+)\.\.(\d+)$/.exec(range);
  assert(match?.[1] && match[2], 'expected --seeds 0..N');
  for (let seed = Number(match[1]); seed <= Number(match[2]); seed++) await scenario(seed);
} catch (error) {
  await writeFile("/tmp/m3b-tiny.log", logs);
  console.error(logs.slice(-3000));
  throw error;
} finally {
  if (tiny.exitCode === null) {
    const exited = once(tiny, 'exit');
    tiny.kill();
    await exited;
  }
  await rm(temporary, { recursive: true, force: true });
}
// The TS summarizer leaves race timers alive after disposal; all owned resources are closed.
process.exit(0);
