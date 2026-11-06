// M4 client construction shared by the TS peer process and the harness's creator: the real 3.11.0
// `OdspClient` with fake storage/push tokens, the M4 container schema, and telemetry collection.
import { OdspClient } from '@fluidframework/odsp-client/beta';
import type { IOdspFluidContainer } from '@fluidframework/odsp-client/beta';
import { SharedMap, SharedString } from 'fluid-framework/legacy';
import type { ITelemetryBaseEvent } from '@fluidframework/core-interfaces';
import { isFluidHandle, toFluidHandleInternal } from '@fluidframework/runtime-utils/internal';
import { z } from 'zod';

export const m4Schema = { initialObjects: { map: SharedMap, text: SharedString } };
export type M4Container = IOdspFluidContainer<typeof m4Schema>;

/** Driver/loader telemetry that means something failed or was retried. */
const retryEvent = /(_firstFailed|_maxRetriesExceeded|_lastError|_runWithRetryAborted|MultipleRetries|DeltaConnectionFailureToConnect|FlushExtraCall)$/;

export interface PeerEvent {
  readonly eventName: string;
  readonly category: string;
  readonly detail: string;
}

/** Collects every error-category event and every retry event the client's stack emits. */
export function eventCollector(sink: PeerEvent[]): { send(event: ITelemetryBaseEvent): void } {
  return {
    send(event: ITelemetryBaseEvent): void {
      if (event.category !== 'error' && !retryEvent.test(event.eventName)) {
        return;
      }
      sink.push({ eventName: event.eventName, category: event.category, detail: JSON.stringify(event).slice(0, 2000) });
    },
  };
}

export function m4Client(siteUrl: string, driveId: string, user: string, events: PeerEvent[]): OdspClient {
  return new OdspClient({
    connection: {
      siteUrl,
      driveId,
      filePath: '',
      tokenProvider: {
        fetchStorageToken: async () => ({ token: `storage:${user}` }),
        fetchWebsocketToken: async () => ({ token: `push:${user}` }),
      },
    },
    logger: eventCollector(events),
  });
}

/** JSON view of the SharedMap; blob handles become `{ type: "__fluid_handle__", url }` (as M2). */
export function mapEntries(container: M4Container): Record<string, unknown> {
  const replacer = (_key: string, value: unknown) =>
    isFluidHandle(value) ? { type: '__fluid_handle__', url: toFluidHandleInternal(value).absolutePath } : value;
  return z.record(z.string(), z.unknown()).parse(JSON.parse(JSON.stringify(Object.fromEntries(container.initialObjects.map.entries()), replacer)));
}
