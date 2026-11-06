import assert from 'node:assert/strict';
import { mock } from 'node:test';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { EpochTrackerWithRedemption } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
function failure(error: unknown): unknown {
    if (!(error instanceof Error))
        throw error;
    const fields = error as Error & {
        errorType: string;
        canRetry: boolean;
        statusCode: number;
    };
    return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode };
}
export async function redemptionOracle(origin: string, mode: string, attempts: () => number): Promise<unknown> {
    if (mode === 'timeout')
        mock.timers.enable({ apis: ['setTimeout'] });
    const timers = mock.method(globalThis, 'setTimeout');
    try {
        const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
        const tracker = new EpochTrackerWithRedemption({ get: async () => undefined, put: async () => { }, removeEntries: async () => { } }, { docId: 'doc', resolvedUrl: resolved }, new MockLogger().toTelemetryLogger(), false);
        const join = tracker.fetchAndParseAsJSON(origin + '/redeem/join', {}, 'joinSession').then(() => ({ ok: true }), failure);
        if (mode === 'timeout') {
            for (let turn = 0; turn < 1000 && !timers.mock.calls.some(call => call.arguments[1] === 15000); turn++)
                await new Promise<void>(resolve => setImmediate(resolve));
            assert(timers.mock.calls.some(call => call.arguments[1] === 15000), 'redemption wait installed');
            mock.timers.tick(14999);
            const before = attempts();
            mock.timers.tick(1);
            return { before, join: await join };
        }
        const tree = tracker.fetchAndParseAsJSON(origin + '/redeem/tree', {}, 'treesLatest').then(() => ({ ok: true }), failure);
        return { join: await join, tree: await tree };
    }
    finally {
        timers.mock.restore();
        if (mode === 'timeout')
            mock.timers.reset();
    }
}
