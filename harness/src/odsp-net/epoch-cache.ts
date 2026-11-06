import { mock } from 'node:test';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { EpochTracker } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
export interface CacheCase {
    type: string;
    value?: unknown;
    epoch?: string;
    put?: unknown;
}
export const cacheCases: CacheCase[] = [
    { type: 'ops' },
    { type: 'ops', value: { version: 2, fluidEpoch: 'E', value: 'old' } },
    { type: 'ops', value: { version: 3, fluidEpoch: 'E', value: '[null,{"sequenceNumber":1}]' } },
    { type: 'ops', epoch: 'F', value: { version: 3, fluidEpoch: 'E', value: 'wrong epoch' } },
    { type: 'snapshot', value: { version: 3, fluidEpoch: 'E', value: { cacheEntryTime: 0, data: 'expired' } } },
    { type: 'snapshot', value: { version: 3, fluidEpoch: 'E', value: { cacheEntryTime: 1, data: 'valid' } } },
    { type: 'snapshot', value: { version: 3, fluidEpoch: 'E', value: { data: 'missing time' } } },
    { type: 'ops', epoch: 'E', put: 'ops string' },
    { type: 'snapshot', epoch: 'E', put: { data: 'snapshot' } },
    { type: 'snapshot', epoch: 'E', put: { data: 'snapshot', cacheEntryTime: 42 } },
];
export async function epochCacheOracle(origin: string): Promise<unknown> {
    mock.timers.enable({ apis: ['Date'], now: 432000000 });
    try {
        const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
        const results: unknown[] = [];
        for (const item of cacheCases) {
            let clears = 0;
            const puts: unknown[] = [];
            const tracker = new EpochTracker({ get: async () => item.value, put: async (entry, value: unknown) => { puts.push({ type: entry.type, key: entry.key, docId: entry.file.docId, value }); }, removeEntries: async () => { clears++; } }, { docId: 'doc', resolvedUrl: resolved }, new MockLogger().toTelemetryLogger(), false);
            if (item.epoch !== undefined)
                tracker.setEpoch(item.epoch, false, 'test');
            const value: unknown = await tracker.get({ type: item.type, key: 'key' });
            if (item.put !== undefined)
                await tracker.put({ type: item.type, key: 'key' }, structuredClone(item.put));
            results.push({ value: value ?? null, epoch: tracker.fluidEpoch ?? null, clears, puts });
        }
        return results;
    }
    finally {
        mock.timers.reset();
    }
}
