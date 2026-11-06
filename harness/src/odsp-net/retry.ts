import assert from 'node:assert/strict';
import { mock } from 'node:test';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { runWithRetry } from '../../node_modules/@fluidframework/odsp-driver/lib/retryUtils.js';

/** Real TS retry wrapper, with Node's timer/Date virtualization instead of wall-clock sleeps. */
export async function retryOracle(): Promise<{ attemptTimes: number[]; canRetry: boolean }> {
    mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
    const originalRandom = Math.random;
    Math.random = () => 0;
    try {
        const attemptTimes: number[] = [];
        let canRetry = true;
        let settled = false;
        const pending = runWithRetry(async () => {
            attemptTimes.push(Date.now());
            throw Object.assign(new Error('coherency'), { errorType: 'throttlingError', canRetry: true, Odsp409Error: true, retryAfterSeconds: 1 });
        }, 'test', new MockLogger().toTelemetryLogger()).catch((error: unknown) => {
            assert(error instanceof Error && 'canRetry' in error && typeof error.canRetry === 'boolean');
            canRetry = error.canRetry;
        }).finally(() => { settled = true; });
        for (let tick = 0; tick < 10 && !settled; tick++) {
            for (let turn = 0; turn < 20; turn++) await Promise.resolve();
            if (!settled) mock.timers.tick(1000);
        }
        await pending;
        assert.deepEqual(attemptTimes, [0, 1000, 2000, 3000, 4000]);
        return { attemptTimes, canRetry };
    } finally {
        Math.random = originalRandom;
        mock.timers.reset();
    }
}
