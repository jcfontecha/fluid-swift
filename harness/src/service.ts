import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { createDetachedContainer, loadExistingContainer, loadSummarizerContainerAndMakeSummary } from '@fluidframework/container-loader/internal';
import { isIDeltaManagerFull } from '@fluidframework/container-definitions/internal';
import type { IContainer } from '@fluidframework/container-definitions/internal';
import { createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { SharedMap } from '@fluidframework/map/internal';
import { RouterliciousDocumentServiceFactory } from '@fluidframework/routerlicious-driver/internal';
import type { IDocumentService } from '@fluidframework/driver-definitions/internal';
import { InsecureTinyliciousTokenProvider, InsecureTinyliciousUrlResolver, createTinyliciousCreateNewRequest } from '@fluidframework/tinylicious-driver/internal';
import { Quorum } from '../node_modules/@fluidframework/container-loader/lib/protocol/quorum.js';
import { Random } from './random.js';

const root = resolve(import.meta.dirname, '../..');
const endpoint = 'http://localhost:7073';
const objectSchema = z.record(z.string(), z.unknown());
const opSchema = objectSchema.and(z.object({ sequenceNumber: z.number() }));
const viewSchema = z.object({ sequenceNumber: z.number(), snapshotSequenceNumber: z.number(), minimumSequenceNumber: z.number(), members: z.array(z.unknown()), proposals: z.array(z.unknown()), values: z.array(z.unknown()), audience: z.array(z.unknown()), ops: z.array(opSchema), opSources: z.array(z.enum(["storage", "socket"])), signals: z.array(z.unknown()), connected: z.boolean() });
const rpcSchema = z.object({ id: z.number(), result: z.unknown().optional(), error: z.object({ message: z.string() }).optional() });
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function until(test: () => boolean | Promise<boolean>, label: string): Promise<void> {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) { if (await test()) return; await sleep(20); }
  throw new Error(`Timeout: ${label}`);
}
class Swift {
  readonly child = spawn(resolve(root, '.build/debug/FluidServicePeer'), [], { cwd: root });
  readonly lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
  id = 0;
  constructor(readonly trace: unknown[]) { this.child.stderr.pipe(process.stderr); }
  async call(method: string, client: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const request = { jsonrpc: '2.0', id: ++this.id, method, params: { client, ...params } };
    this.trace.push({ request }); this.child.stdin.write(JSON.stringify(request) + '\n');
    let timer: NodeJS.Timeout | undefined;
    const line = await Promise.race([this.lines.next(), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('Swift RPC timeout')), 30000); })]).finally(() => clearTimeout(timer));
    assert(!line.done, 'Swift exited');
    const response = rpcSchema.parse(JSON.parse(line.value)); this.trace.push({ response });
    assert.equal(response.id, this.id);
    if (response.error) throw new Error(response.error.message);
    return response.result;
  }
  async view(client: string) { return viewSchema.parse(await this.call('view', client)); }
  async close() { if (this.child.exitCode === null) { const exited = once(this.child, 'exit'); this.child.kill(); await exited; } }
}
const schema = { initialObjects: { map: SharedMap } };
function props() {
  return {
    urlResolver: new InsecureTinyliciousUrlResolver({ port: 7073 }),
    documentServiceFactory: new RouterliciousDocumentServiceFactory(new InsecureTinyliciousTokenProvider()),
    codeLoader: { load: async () => ({ module: { fluidExport: createDOProviderContainerRuntimeFactory({ schema, oldestSupportedClient: '2.0.0', runtimeOptionOverrides: { summaryOptions: { summaryConfigOverrides: { state: 'disableHeuristics', initialSummarizerDelayMs: 0, maxAckWaitTime: 20000, maxOpsSinceLastSummary: 7000 } } } }) }, details: { package: 'service-map' } }) },
    clientDetailsOverride: { capabilities: { interactive: true } },
    configProvider: { getRawConfig: (name: string) => name === 'Fluid.Container.ForceWriteConnection' ? true : undefined },
  };
}
function observe(container: IContainer) {
  const ops: string[] = [];
  assert(isIDeltaManagerFull(container.deltaManager));
  container.deltaManager.inbound.on('push', op => { ops.push(JSON.stringify(op)); });
  return ops;
}
function tsView(container: IContainer) {
  const quorum = container.getQuorum();
  assert(quorum instanceof Quorum, 'oracle quorum implementation changed');
  return { sequenceNumber: container.deltaManager.lastSequenceNumber, minimumSequenceNumber: container.deltaManager.minimumSequenceNumber, ...quorum.snapshot(), audience: [...container.audience.getMembers()] };
}
async function scenario(seed: number) {
  const trace: unknown[] = [{ seed }];
  const swift = new Swift(trace);
  const containers: IContainer[] = [];
  let oracleService: IDocumentService | undefined;
  try {
    const creator = await createDetachedContainer({ ...props(), codeDetails: { package: 'service-map' } }); containers.push(creator);
    const ops = observe(creator);
    const receivedSignals: string[] = [];
    creator.deltaManager.inboundSignal.on('push', signal => { receivedSignals.push(JSON.stringify(signal)); });
    await creator.attach(createTinyliciousCreateNewRequest());
    const document = creator.resolvedUrl?.id; assert(document);
    await until(() => creator.connectionState === 2, 'TS creator connected');
    const resolved = await props().urlResolver.resolve({ url: document }); assert(resolved?.type === 'fluid');
    oracleService = await props().documentServiceFactory.createDocumentService(resolved);
    const oracleStorage = await oracleService.connectToDeltaStorage();
    const fluid = await createFluidContainer<typeof schema>({ container: creator });
    await swift.call('open', 'start', { endpoint, document });
    await until(async () => (await swift.view('start')).connected, 'Swift own join');
    async function checkpoint(clients: string[], label: string) {
      await until(async () => {
        const views = [];
        for (const client of clients) views.push(await swift.view(client));
        return views.every(view => view.sequenceNumber === creator.deltaManager.lastSequenceNumber);
      }, label);
      const expected = tsView(creator);
      const stored = new Map<number, string>();
      const stream = oracleStorage.fetchMessages(1, expected.sequenceNumber + 1);
      for (;;) { const batch = await stream.read(); if (batch.done) break; for (const op of batch.value) stored.set(op.sequenceNumber, JSON.stringify(op)); }
      trace.push({ label, expected });
      for (const client of clients) {
        const actual = await swift.view(client); trace.push({ client, actual });
        assert.equal(actual.sequenceNumber, expected.sequenceNumber, `${label}: sequence`);
        for (const key of ['minimumSequenceNumber', 'members', 'proposals', 'values', 'audience'] as const) assert.deepEqual(actual[key], expected[key], `${label}: ${client} ${key}`);
        const observed = new Map(ops.map(text => [opSchema.parse(JSON.parse(text)).sequenceNumber, text]));
        assert.equal(actual.ops.length, actual.sequenceNumber - actual.snapshotSequenceNumber, `${label}: missing observation`);
        assert.equal(actual.opSources.length, actual.ops.length);
        assert(actual.ops.length > 0, 'no overlapping ops compared');
        for (const [index, op] of actual.ops.entries()) {
          assert.equal(op.sequenceNumber, actual.snapshotSequenceNumber + index + 1, `${label}: log gap`);
          const ts = actual.opSources[index] === "storage" ? stored.get(op.sequenceNumber) : observed.get(op.sequenceNumber);
          assert(ts !== undefined, `${label}: missing TS observation ${op.sequenceNumber}`);
          assert.equal(JSON.stringify(op), ts, `${label}: raw op ${op.sequenceNumber}`);
        }
      }
    }
    await checkpoint(['start'], 'creation');
    const random = new Random(seed);
    for (let i = 0, count = 60 + random.int(40); i < count; i++) { fluid.initialObjects.map.set(`key-${i}`, random.int(10000)); await sleep(1 + random.int(3)); }
    await until(() => !creator.isDirty, 'TS edits saved');
    await checkpoint(['start'], 'edits');
    const summarized = await loadSummarizerContainerAndMakeSummary({ ...props(), request: { url: document } });
    trace.push({ summarized });
    assert(summarized.success && summarized.summaryResults.summarySubmitted && summarized.summaryResults.summaryOpBroadcasted, 'summarizer failed');
    await until(() => ops.some(text => objectSchema.parse(JSON.parse(text)).type === 'summaryAck'), 'summary ACK sequenced');
    await checkpoint(['start'], 'summary ack');
    await swift.call('open', 'mid', { endpoint, document });
    await until(async () => (await swift.view('mid')).connected, 'mid-stream own join');
    assert((await swift.view('mid')).snapshotSequenceNumber > 0, 'mid client did not load a sequenced snapshot');
    await checkpoint(['start', 'mid'], 'snapshot join');
    const other = await loadExistingContainer({ ...props(), request: { url: document } }); containers.push(other);
    await until(() => other.connectionState === 2, 'TS second connected');
    const otherFluid = await createFluidContainer<typeof schema>({ container: other });
    otherFluid.initialObjects.map.set('other-writer', seed);
    await until(() => !other.isDirty, 'second writer saved');
    await checkpoint(['start', 'mid'], 'TS join');
    assert(isIDeltaManagerFull(other.deltaManager));
    await other.deltaManager.outbound.pause();
    const quorum = creator.getQuorum(); assert(quorum instanceof Quorum);
    const proposal = quorum.propose(`proposal-${seed}`, { seed });
    // A pending proposal checkpoint is important: testing only settled values misses dropped proposals.
    await until(() => quorum.snapshot().proposals.length > 0, 'pending proposal');
    await checkpoint(['start', 'mid'], 'pending proposal');
    other.deltaManager.outbound.resume();
    await proposal;
    other.disconnect();
    await checkpoint(['start', 'mid'], 'committed proposal and leave');
    await swift.call('signal', 'start', { content: JSON.stringify({ contents: { type: 'm1-signal', content: { seed } } }) });
    await until(async () => receivedSignals.some(text => text.includes('m1-signal')) && (await swift.view('mid')).signals.some(signal => JSON.stringify(signal).includes('m1-signal')), 'TS and Swift signal received');
    const tsSignal = receivedSignals.find(text => text.includes('m1-signal')); assert(tsSignal);
    for (const client of ['start', 'mid']) {
      const signal = (await swift.view(client)).signals.find(signal => JSON.stringify(signal).includes('m1-signal'));
      assert.equal(JSON.stringify(signal), tsSignal, 'raw signal differs');
    }
    await swift.call('disconnect', 'start');
    fluid.initialObjects.map.set('offline', seed);
    await until(() => !creator.isDirty, 'offline edit saved');
    await swift.call('reconnect', 'start');
    await until(async () => (await swift.view('start')).connected, 'reconnected own join');
    await checkpoint(['start', 'mid'], 'reconnect catchup');
    console.log(`service seed ${seed}: passed`);
  } catch (error) {
    trace.push({ failure: String(error) });
    await mkdir(resolve(root, 'harness/traces'), { recursive: true });
    await writeFile(resolve(root, `harness/traces/service-${seed}.jsonl`), trace.map(entry => JSON.stringify(entry)).join('\n') + '\n');
    throw error;
  } finally { for (const container of containers) container.dispose(); oracleService?.dispose(); await swift.close(); }
}
const temporary = await mkdtemp(join(tmpdir(), 'fluid-service-'));
const tiny = spawn(process.execPath, [resolve(root, 'harness/node_modules/tinylicious/dist/index.js')], { cwd: temporary, env: { ...process.env, PORT: '7073', storage: join(temporary, 'storage') }, stdio: ['ignore', 'pipe', 'pipe'] });
let logs = ''; tiny.stdout.on('data', (chunk: Buffer) => { logs += chunk.toString(); }); tiny.stderr.on('data', (chunk: Buffer) => { logs += chunk.toString(); });
try {
  await until(async () => { if (tiny.exitCode !== null) throw new Error(logs); try { return (await fetch(endpoint)).ok; } catch { return false; } }, 'tinylicious 7073 startup');
  const range = process.argv[process.argv.indexOf('--seeds') + 1] ?? '0..9';
  const match = /^(\d+)\.\.(\d+)$/.exec(range); assert(match?.[1] && match[2], 'expected --seeds 0..N');
  for (let seed = Number(match[1]); seed <= Number(match[2]); seed++) await scenario(seed);
} catch (error) { console.error(logs.slice(-3000)); throw error; }
finally { const exited = once(tiny, 'exit'); tiny.kill(); await exited; await rm(temporary, { recursive: true, force: true }); }
// The oracle's Summarizer.runCore leaves two 120-second race timers alive even after
// disposal (summaryDelayLoadedModule/summarizer.ts). All clients, child processes and
// storage are already cleaned up above; this finite CLI must not wait on oracle timers.
process.exit(0);
