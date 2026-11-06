import { mock } from 'node:test';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { OdspDocumentStorageService } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDocumentStorageManager.js';
import { NonPersistentCache } from '../../node_modules/@fluidframework/odsp-driver/lib/odspCache.js';
import { EpochTracker } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
export async function snapshotManagerOracle(origin: string, kind: string): Promise<unknown> {
    const logger = new MockLogger().toTelemetryLogger();
    const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const persistedCache = { get: async () => undefined, put: async () => { }, removeEntries: async () => { } };
    const tracker = new EpochTracker(persistedCache, { docId: 'doc', resolvedUrl: resolved }, logger, false);
    const options = kind === 'limited' ? { blobs: 2, mds: 123 } : kind === 'timeout' ? { blobs: 2, timeout: 5000 } : { blobs: 2 };
    const timers = mock.method(globalThis, 'setTimeout');
    const timeouts = (): number[] => timers.mock.calls.map(call => call.arguments[1]).filter((value): value is number => value === 120000 || value === 5000);
    const storage = new OdspDocumentStorageService(resolved, async () => 'Bearer initial', logger, true, { ...new NonPersistentCache(), persistedCache }, { summarizerClient: kind === 'summarizer', snapshotOptions: options }, tracker, async () => ({}), () => undefined);
    try {
        const snapshot = await storage['fetchSnapshotFromNetwork'](options, undefined, undefined, true);
        return { sequenceNumber: snapshot.sequenceNumber, blobs: snapshot.blobContents.size, timeouts: timeouts() };
    }
    catch (error) {
        if (!(error instanceof Error))
            throw error;
        const fields = error as Error & {
            errorType: string;
            canRetry: boolean;
            statusCode?: number;
        };
        return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode, timeouts: timeouts() };
    }
    finally {
        timers.mock.restore();
    }
}
export async function snapshotRaceOracle(origin: string, kind: string): Promise<unknown> {
    const logger = new MockLogger().toTelemetryLogger();
    const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    let resolvePut: (() => void) | undefined;
    const put = new Promise<void>(resolve => { resolvePut = resolve; });
    const persistedCache = {
        get: async () => {
            if (kind === 'networkFirst' || kind === 'networkFailure' || kind === 'bothFailureNetworkFirst')
                await new Promise<void>(resolve => setTimeout(resolve, 25));
            if (kind === 'cacheMiss')
                return undefined;
            if (kind === 'cacheFailure' || kind.startsWith('bothFailure'))
                throw new Error('cache failure');
            return { version: 3, fluidEpoch: 'E', value: { snapshotTree: { id: 'cached', blobs: {}, trees: {} }, blobContents: new Map(), ops: [], sequenceNumber: 10, snapshotFormatV: 1, cacheEntryTime: Date.now() } };
        },
        put: async () => { resolvePut?.(); },
        removeEntries: async () => { },
    };
    const tracker = new EpochTracker(persistedCache, { docId: 'doc', resolvedUrl: resolved }, logger, false);
    const storage = new OdspDocumentStorageService(resolved, async () => 'Bearer initial', logger, true, { ...new NonPersistentCache(), persistedCache: tracker }, { concurrentSnapshotFetch: true }, tracker, async () => ({}), () => undefined);
    try {
        const { snapshot } = await storage['fetchSnapshot']({});
        if (kind !== 'networkFailure')
            await put;
        return { sequenceNumber: snapshot.sequenceNumber };
    }
    catch (error) {
        if (!(error instanceof Error))
            throw error;
        if (error.message === 'cache failure')
            return { failure: 'cache' };
        const fields = error as Error & {
            errorType: string;
            canRetry: boolean;
            statusCode: number;
        };
        return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode };
    }
}
