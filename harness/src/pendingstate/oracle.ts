import { DuplicateBatchDetector } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/duplicateBatchDetector.js';
import type { BatchStartInfo } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/remoteMessageProcessor.js';
export interface Batch {
    sequenceNumber: number;
    minimumSequenceNumber: number;
    clientId: string;
    batchStartCsn: number;
    batchId?: string;
}
export interface Scenario {
    snapshot: [number, string][];
    commands: ({ kind: 'process'; batch: Batch } | { kind: 'summary' } | { kind: 'reload' })[];
}
export function run(scenario: Scenario): string {
    let detector = new DuplicateBatchDetector(scenario.snapshot);
    const results: unknown[] = [];
    for (const command of scenario.commands) {
        if (command.kind === 'process') {
            const b = command.batch;
            const batch: BatchStartInfo = {
                clientId: b.clientId,
                batchStartCsn: b.batchStartCsn,
                batchId: b.batchId,
                keyMessage: {
                    type: 'op',
                    contents: {},
                    clientId: b.clientId,
                    clientSequenceNumber: b.batchStartCsn,
                    sequenceNumber: b.sequenceNumber,
                    minimumSequenceNumber: b.minimumSequenceNumber,
                    referenceSequenceNumber: 0,
                    timestamp: 0,
                },
            };
            results.push(detector.processInboundBatch(batch));
        } else {
            const summary = detector.getRecentBatchInfoForSummary();
            results.push(summary ?? null);
            if (command.kind === 'reload') {
                detector = new DuplicateBatchDetector(summary);
            }
        }
    }
    return JSON.stringify(results);
}
