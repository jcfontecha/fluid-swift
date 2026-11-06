// `npx tsx src/odsp-service/replay.ts <service-m4-…odsp.json> [--port 7098]`: loads a failing M4
// file's dumped storage into a local ODSP service and opens it with the real 3.11.0 driver once per
// committed snapshot, each time catching up on every stored op without a push connection. Every
// load must reach the same state; a load that differs from the replay of the full op log (the
// creation snapshot) points at that summary, and loads that all differ from live state point at
// the op log.
import { readFile } from 'node:fs/promises';
import { z } from 'zod';
import { LoaderHeader } from '@fluidframework/container-definitions/internal';
import { loadExistingContainer } from '@fluidframework/container-loader/internal';
import { createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { OdspDocumentServiceFactory, OdspDriverUrlResolver, createOdspUrl } from '@fluidframework/odsp-driver/internal';
import { OdspLocalService } from './server.js';
import { eventCollector, m4Schema, type PeerEvent } from './m4-client.js';
import type { FileDump } from './store.js';

const path = process.argv[2];
if (path === undefined) {
  throw new Error('usage: replay.ts <dump.odsp.json> [--port N]');
}
const portIndex = process.argv.indexOf('--port');
const port = z.coerce.number().int().min(7095).max(7099).parse(portIndex < 0 ? '7098' : process.argv[portIndex + 1]);
const dump: FileDump = JSON.parse(await readFile(path, 'utf8'));
const service = await OdspLocalService.start(port);
const file = service.drive.restore(dump);
const info = service.connectionInfo();
const runtimeFactory = createDOProviderContainerRuntimeFactory({ schema: m4Schema, oldestSupportedClient: '2.0.0' });

/** Loads from the snapshot `snapshotId`, then applies every stored op ("all" trailing ops, no socket). */
async function load(snapshotId: string): Promise<{ text: string; map: unknown; sequenceNumber: number; events: PeerEvent[] }> {
  file.latestId = snapshotId;
  const events: PeerEvent[] = [];
  const factory = new OdspDocumentServiceFactory(async () => ({ token: 'storage:replay' }), async () => ({ token: 'push:replay' }));
  const container = await loadExistingContainer({
    urlResolver: new OdspDriverUrlResolver(),
    documentServiceFactory: factory,
    codeLoader: {
      load: async () => ({ module: { fluidExport: runtimeFactory }, details: { package: 'no-dynamic-package', config: {} } }),
    },
    logger: eventCollector(events),
    request: {
      url: createOdspUrl({ siteUrl: info.siteUrl, driveId: info.driveId, itemId: file.itemId, dataStorePath: '' }),
      headers: { [LoaderHeader.loadMode]: { opsBeforeReturn: 'all', deltaConnection: 'delayed' } },
    },
  });
  const fluid = await createFluidContainer<typeof m4Schema>({ container });
  const result = {
    text: fluid.initialObjects.text.getText(),
    map: Object.fromEntries(fluid.initialObjects.map.entries()),
    sequenceNumber: container.deltaManager.lastSequenceNumber,
    events,
  };
  container.dispose();
  return result;
}

const snapshots = [...file.snapshots.values()].sort((a, b) => a.sequenceNumber - b.sequenceNumber);
const results = [];
for (const snapshot of snapshots) {
  const result = await load(snapshot.id);
  results.push({ snapshot: snapshot.sequenceNumber, ...result });
}
const reference = results[0];
for (const result of results) {
  const sameText = result.text === reference?.text;
  const sameMap = JSON.stringify(result.map) === JSON.stringify(reference?.map);
  console.log(`from snapshot ${result.snapshot}: reached ${result.sequenceNumber}, text ${sameText ? 'same' : 'DIFFERENT'}, map ${sameMap ? 'same' : 'DIFFERENT'} as full replay, events ${result.events.length}`);
}
console.log(JSON.stringify(results.map(result => ({ snapshot: result.snapshot, text: result.text })), null, 1));
await service.close();
process.exit(0);
