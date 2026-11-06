import assert from 'node:assert/strict';
import { socketClient } from './socket.js';
import { mock } from 'node:test';
import { MockLogger, loggerToMonitoringContext } from '@fluidframework/telemetry-utils/internal';
import { OdspDelayLoadedDeltaStream } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDelayLoadedDeltaStream.js';
import { NonPersistentCache } from '../../node_modules/@fluidframework/odsp-driver/lib/odspCache.js';
import { EpochTracker } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
/** Real discovery cache, driven at the exact 30-second refresh-buffer boundary. */
export async function joinOracle(origin: string): Promise<unknown> {
    mock.timers.enable({ apis: ['Date'], now: 0 });
    const logger = new MockLogger().toTelemetryLogger();
    const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const persistedCache = { get: async () => undefined, put: async () => { }, removeEntries: async () => { } };
    const tracker = new EpochTracker(persistedCache, { docId: 'doc', resolvedUrl: resolved }, logger, false);
    const stream = new OdspDelayLoadedDeltaStream(resolved, {}, async () => 'Bearer initial', undefined, loggerToMonitoringContext(logger), { ...new NonPersistentCache(), persistedCache }, {}, tracker, () => { }, () => { });
    try {
        const values: unknown[] = [];
        for (const now of [0, 1000, 3569999, 3570000]) {
            mock.timers.setTime(now);
            const value = await stream['joinSessionCore'](true, { refresh: false }, false, 'Guest');
            values.push({ value, refreshAfter: stream['calculateJoinSessionRefreshDelta'](now === 3570000 ? now : 0, 3600) });
        }
        return values;
    }
    finally {
        stream['clearJoinSessionTimer']();
        mock.timers.reset();
    }
}
export async function joinLiveOracle(origin: string): Promise<unknown> {
    mock.timers.enable({ apis: ['Date'], now: 0 });
    const logger = new MockLogger().toTelemetryLogger();
    const resolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const persistedCache = { get: async () => undefined, put: async () => { }, removeEntries: async () => { } };
    const tracker = new EpochTracker(persistedCache, { docId: 'doc', resolvedUrl: resolved }, logger, false);
    const stream = new OdspDelayLoadedDeltaStream(resolved, {}, async () => 'Bearer initial', undefined, loggerToMonitoringContext(logger), { ...new NonPersistentCache(), persistedCache }, { sessionOptions: { displayName: 'Guest' } }, tracker, () => { }, () => { });
    try {
        await stream.connectToDeltaStream(socketClient);
        const connection = stream.currentDeltaConnection;
        assert(connection);
        mock.timers.setTime(3570000);
        await stream['scheduleJoinSessionRefresh'](0, true, connection.clientId, 'Guest');
        try {
            await connection.flush();
        }
        catch (error) {
            if (!(error instanceof Error))
                throw error;
        }
        const disconnected = stream.currentDeltaConnection === undefined;
        const timerCleared = stream['joinSessionRefreshTimer'] === undefined;
        const value = await stream['joinSessionCore'](true, { refresh: false }, false, 'Guest');
        return { disconnected, timerCleared, value };
    }
    finally {
        stream.currentDeltaConnection?.dispose();
        stream['clearJoinSessionTimer']();
        mock.timers.reset();
    }
}
