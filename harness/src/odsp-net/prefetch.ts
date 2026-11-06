import assert from 'node:assert/strict';
import { mock } from 'node:test';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { getKeyForCacheEntry } from '@fluidframework/driver-utils/internal';
import { prefetchLatestSnapshot } from '../../node_modules/@fluidframework/odsp-driver/lib/prefetchLatestSnapshot.js';
import { OdspDocumentServiceFactory } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDocumentServiceFactory.js';
import { createCacheSnapshotKey } from '../../node_modules/@fluidframework/odsp-driver/lib/odspUtils.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
export async function prefetchOracle(origin: string, failPut: boolean): Promise<unknown> {
    mock.timers.enable({ apis: ['setTimeout'] });
    // fetchLatestSnapshotCore intentionally does not await putInCache's wrapper promise.
    // Observe its duplicate rejection without changing the oracle or terminating Node.
    let putRejections = 0;
    const onRejection = (error: unknown): void => {
        if (!(error instanceof Error) || error.message !== 'persisted put failed')
            throw error;
        putRejections++;
    };
    process.on('unhandledRejection', onRejection);
    try {
        let resolvePut: (() => void) | undefined;
        let rejectPut: ((error: Error) => void) | undefined;
        const gate = new Promise<void>((resolve, reject) => { resolvePut = resolve; rejectPut = reject; });
        const persisted = { get: async () => undefined, put: () => gate, removeEntries: async () => { } };
        const factory = new OdspDocumentServiceFactory(async () => 'initial', undefined, persisted);
        const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
        let settled = false;
        const result = prefetchLatestSnapshot(resolved, async () => 'initial', persisted, false, new MockLogger(), undefined, true, undefined, undefined, factory).finally(() => { settled = true; });
        const key = getKeyForCacheEntry(createCacheSnapshotKey(resolved, false));
        const deferred = factory.snapshotPrefetchResultCache.get(key);
        assert(deferred, 'prefetch publishes its deferred before downloading');
        const snapshot = await deferred;
        const publishedBeforePut = !settled;
        if (failPut)
            rejectPut?.(new Error('persisted put failed'));
        else
            resolvePut?.();
        const success = await result;
        mock.timers.tick(4999);
        const beforeFiveSeconds = factory.snapshotPrefetchResultCache.get(key) !== undefined;
        mock.timers.tick(1);
        const afterFiveSeconds = factory.snapshotPrefetchResultCache.get(key) !== undefined;
        await new Promise<void>(resolve => setImmediate(resolve));
        if (failPut)
            assert(putRejections > 0);
        return { sequenceNumber: snapshot.sequenceNumber, publishedBeforePut, success, beforeFiveSeconds, afterFiveSeconds };
    }
    finally {
        process.off('unhandledRejection', onRejection);
        mock.timers.reset();
    }
}
