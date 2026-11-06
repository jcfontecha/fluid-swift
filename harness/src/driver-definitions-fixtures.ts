// Real 3.11.0 traffic, captured at driver boundaries; no private-member casts.
import './driver-definitions-vectors.js';
import { spawn, type ChildProcess } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Socket } from 'socket.io-client';
import { z } from 'zod';
import { ContainerRuntime, neverCancelledSummaryToken } from '@fluidframework/container-runtime/internal';
import { SharedMap } from '@fluidframework/map/internal';
import { Loader, type IQuorumSnapshot } from '@fluidframework/container-loader/internal';
import type { IContainer, IContainerContext } from '@fluidframework/container-definitions/internal';
import type { IClient, IDocumentService, IQuorum } from '@fluidframework/driver-definitions/internal';
import { createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { RouterliciousDocumentServiceFactory } from '@fluidframework/routerlicious-driver/internal';
import { createChildLogger } from '@fluidframework/telemetry-utils/internal';
import { createTinyliciousCreateNewRequest, InsecureTinyliciousTokenProvider, InsecureTinyliciousUrlResolver } from '@fluidframework/tinylicious-driver/internal';

const records: {type: string; text: string; source: string}[] = [];
function capture(type: string, value: unknown, source = 'session'): void {
  const text = JSON.stringify(value);
  if (text !== undefined) records.push({type, text, source});
}
const originalEmit = Socket.prototype.emit;
Socket.prototype.emit = function(event, ...args) {
  if (event === 'connect_document') {
    capture('IConnect', args[0]);
    this.once('connect_document_success', (value: unknown) => capture('IConnected', value));
  }
  return originalEmit.call(this, event, ...args);
};
async function until(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 30000;
  while (!predicate()) {
    if (Date.now() > deadline) throw Error(`Timed out: ${label}`);
    await new Promise(r => setTimeout(r, 25));
  }
}
let server: ChildProcess | undefined;
try { await fetch('http://localhost:7071'); }
catch {
  server = spawn(process.execPath, ['node_modules/tinylicious/dist/index.js'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)),
    env: {...process.env, PORT: '7071'}, stdio: ['ignore', 'ignore', 'inherit']
  });
}
const containers: IContainer[] = [];
try {
  for (let n = 0; n < 100; n++) {
    try { await fetch('http://localhost:7071'); break; }
    catch { await new Promise(r => setTimeout(r, 100)); }
  }
  const schema = {initialObjects: {map: SharedMap}};
  const runtimeFactory = createDOProviderContainerRuntimeFactory({schema, oldestSupportedClient: '2.0.0'});
  const runtimes: {runtime: ContainerRuntime; context: IContainerContext}[] = [];
  const instantiate = runtimeFactory.instantiateRuntime.bind(runtimeFactory);
  runtimeFactory.instantiateRuntime = async (context, existing) => {
    const runtime = await instantiate(context, existing);
    if (!(runtime instanceof ContainerRuntime)) throw Error('Expected ContainerRuntime');
    runtimes.push({runtime, context});
    return runtime;
  };
  const factory = new RouterliciousDocumentServiceFactory(new InsecureTinyliciousTokenProvider());
  const wrapped = new Set<IDocumentService>();
  function wrap(service: IDocumentService): IDocumentService {
    if (wrapped.has(service)) return service;
    wrapped.add(service);
    const connect = service.connectToDeltaStream.bind(service);
    service.connectToDeltaStream = async info => {
      capture('IClient', info);
      const connection = await connect(info);
      connection.on('op', (_id, messages) => messages.forEach(m => capture('ISequencedDocumentMessage', m)));
      connection.on('signal', signal => (Array.isArray(signal) ? signal : [signal]).forEach(s => capture('ISignalMessage', s)));
      capture('ITokenClaims', connection.claims);
      capture('IClientConfiguration', connection.serviceConfiguration);
      // IConnected is the actual socket payload, not a reconstruction of the connection API.
      const submit = connection.submit.bind(connection);
      connection.submit = messages => { messages.forEach(m => capture('IDocumentMessage', m)); return submit(messages); };
      return connection;
    };
    const storage = service.connectToStorage.bind(service);
    service.connectToStorage = async () => {
      const result = await storage();
      const upload = result.uploadSummaryWithContext.bind(result);
      result.uploadSummaryWithContext = async (summary, context) => {
        capture('ISummaryTree', summary); capture('ISummaryContext', context);
        return upload(summary, context);
      };
      const getTree = result.getSnapshotTree.bind(result);
      result.getSnapshotTree = async (...args) => { const tree = await getTree(...args); if (tree) capture('ISnapshotTree', tree); return tree; };
      return result;
    };
    return service;
  }
  const create = factory.createContainer.bind(factory);
  factory.createContainer = async (...args) => {
    capture('ISummaryTree', args[0]);
    return wrap(await create(...args));
  };
  const load = factory.createDocumentService.bind(factory);
  factory.createDocumentService = async (...args) => wrap(await load(...args));
  const client: IClient = {details: {capabilities: {interactive: true}}, permission: [], scopes: [], user: {id: ''}, mode: 'write'};
  const props = {
    urlResolver: new InsecureTinyliciousUrlResolver({port: 7071, endpoint: 'http://localhost'}),
    documentServiceFactory: factory,
    codeLoader: {load: async () => ({module: {fluidExport: runtimeFactory}, details: {package: 'no-dynamic-package', config: {}}})},
    options: {client},
    configProvider: {getRawConfig: (name: string) => name === 'Fluid.Container.ForceWriteConnection' ? true : undefined}
  };
  const loader = new Loader(props);
  const a = await loader.createDetachedContainer({package: 'no-dynamic-package', config: {}});
  containers.push(a);
  await a.attach(createTinyliciousCreateNewRequest());
  await until(() => a.connectionState === 2, 'first connected');
  if (!a.resolvedUrl) throw Error('Missing resolved URL');
  const b = await loader.resolve({url: a.resolvedUrl.id});
  containers.push(b);
  await until(() => b.connectionState === 2 && a.getQuorum().getMembers().size >= 2, 'two clients');
  const rootA = await createFluidContainer<typeof schema>({container: a});
  const rootB = await createFluidContainer<typeof schema>({container: b});
  rootA.initialObjects.map.set('golden', {text: 'native Swift', value: 42});
  await until(() => rootB.initialObjects.map.has('golden'), 'map synchronization');
  const first = runtimes[0];
  if (!first) throw Error('Missing first runtime');
  // 3.11.0 declarations hide the still-implemented legacy consensus/snapshot API.
  const protocolQuorum = first.context.quorum as IQuorum & {snapshot(): IQuorumSnapshot};
  protocolQuorum.on('addProposal', proposal => capture('ISequencedProposal', proposal));
  const proposal = protocolQuorum.propose('golden-proposal', {value: 7});
  await new Promise(r => setTimeout(r, 200));
  rootB.initialObjects.map.set('advance', 1);
  await proposal;
  first.runtime.submitSignal('golden-signal', {hello: 'Swift'});
  await until(() => records.some(r => r.type === 'ISignalMessage' && r.text.includes('golden-signal')), 'signal delivery');
  for (const member of a.getQuorum().getMembers().values()) capture('ISequencedClient', member);
  const summary = await first.runtime.summarize({fullTree: true, trackState: false, runGC: false});
  capture('ISummaryTree', summary.summary);
  const summarizerLoader = new Loader({...props,
    options: {...props.options, client: {...client, details: {type: 'summarizer', capabilities: {interactive: false}}}},
  });
  const summarizer = await summarizerLoader.resolve({url: a.resolvedUrl.id});
  containers.push(summarizer);
  await until(() => summarizer.connectionState === 2, 'summarizer connected');
  const last = runtimes.at(-1);
  if (!last) throw Error('Missing summarizer runtime');
  const submitted = await last.runtime.submitSummary({fullTree: true, summaryLogger: createChildLogger(), cancellationToken: neverCancelledSummaryToken, latestSummaryRefSeqNum: 0});
  if (submitted.stage !== 'submit') throw Error(`Summary submission failed: ${JSON.stringify(submitted)}`);
  await until(() => records.some(r => r.type === 'ISequencedDocumentMessage' && z.object({type: z.string()}).parse(JSON.parse(r.text)).type === 'summaryAck'), 'summary acknowledgement');
  const state = {sequenceNumber: a.deltaManager.lastSequenceNumber,
    minimumSequenceNumber: a.deltaManager.minimumSequenceNumber, ...protocolQuorum.snapshot()};
  capture('IProtocolState', state);
  for (const [, value] of state.values) capture('ICommittedProposal', value);
  const message = z.object({type: z.string(), data: z.string().optional(), contents: z.unknown().optional()});
  const payloadTypes: Record<string, string> = {summarize: 'ISummaryContent', summaryAck: 'ISummaryAck', summaryNack: 'ISummaryNack', propose: 'IProposal'};
  for (const record of [...records]) {
    if (record.type !== 'ISequencedDocumentMessage' && record.type !== 'IDocumentMessage') continue;
    const value = message.parse(JSON.parse(record.text));
    if (record.type === 'ISequencedDocumentMessage' && value.data !== undefined) {
      capture('ISequencedDocumentSystemMessage', JSON.parse(record.text));
      if (value.type === 'join') capture('IClientJoin', JSON.parse(value.data));
    }
    const type = payloadTypes[value.type];
    if (type && value.contents !== undefined) capture(type, typeof value.contents === 'string' ? JSON.parse(value.contents) : value.contents);
  }
  await writeFile(new URL('../../Tests/FluidDriverDefinitionsTests/Fixtures/session.json', import.meta.url), JSON.stringify(records, null, 2) + '\n');
  console.log(`Captured ${records.length} real session values`);
} finally {
  Socket.prototype.emit = originalEmit;
  containers.forEach(c => c.close());
  server?.kill('SIGTERM');
}
