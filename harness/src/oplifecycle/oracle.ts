import { assertIsSessionId } from '../../node_modules/@fluidframework/id-compressor/lib/utilities.js';
import type { IBatchMessage } from '@fluidframework/container-definitions/internal';
import type { ISequencedDocumentMessage } from '@fluidframework/driver-definitions/internal';
import { Outbox } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/outbox.js';
import { OpGroupingManager } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opGroupingManager.js';
import { OpCompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opCompressor.js';
import { OpSplitter } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opSplitter.js';
import { OpDecompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opDecompressor.js';
import { RemoteMessageProcessor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/remoteMessageProcessor.js';
import { PendingStateManager } from '../../node_modules/@fluidframework/container-runtime/lib/pendingStateManager.js';
import { ContainerMessageType } from '../../node_modules/@fluidframework/container-runtime/lib/messageTypes.js';
import { CompressionAlgorithms } from '../../node_modules/@fluidframework/container-runtime/lib/compressionDefinitions.js';
export interface Scenario {
    grouped: boolean;
    threshold: number;
    chunkSize: number;
    batches: {
        ops: string[];
        allocation: boolean;
        batchId?: string;
    }[];
}
export const logger = {
    send: () => {
    }
};
export function outbound(s: Scenario): IBatchMessage[][] {
    const wire: IBatchMessage[][] = [];
    let csn = 0;
    let ref = 0;
    let allocation = false;
    const submit = (batch: IBatchMessage[]) => {
        wire.push(structuredClone(batch));
        csn += batch.length;
        return csn;
    };
    const pending = new PendingStateManager({
        connected: () => true, clientId: () => 'sender', applyStashedOp: async () => {
        }, reSubmitBatch: () => {
        }, isActiveConnection: () => true, isAttached: () => true
    }, undefined, logger);
    const outbox = new Outbox({
        shouldSend: () => true, pendingStateManager: pending, submitBatchFn: submit,
        legacySendBatchFn: () => {
            throw Error('legacy');
        }, config: {
            compressionOptions: {
                minimumBatchSizeInBytes: s.threshold, compressionAlgorithm: CompressionAlgorithms.lz4
            }, maxBatchSizeInBytes: 10000000
        },
        compressor: new OpCompressor(logger), splitter: new OpSplitter([], submit, s.chunkSize, 10000000, logger), logger,
        groupingManager: new OpGroupingManager({
            groupedBatchingEnabled: s.grouped
        }, logger), getCurrentSequenceNumbers: () => ({
            referenceSequenceNumber: ref, clientSequenceNumber: 0
        }), reSubmit: () => {
            throw Error('unexpected rebase');
        }, opReentrancy: () => false,
        generateIdAllocationOp: () => allocation ? {
            runtimeOp: {
                type: ContainerMessageType.IdAllocation, contents: {
                    sessionId: assertIsSessionId('00000000-0000-4000-8000-000000000001'), ids: {
                        firstGenCount: ref + 1, count: 1, requestedClusterSize: 512, localIdRanges: [[ref + 1, 1]]
                    }
                }
            }, referenceSequenceNumber: ref
        } : undefined
    });
    for (const b of s.batches) {
        allocation = b.allocation;
        for (const text of b.ops)
            outbox.submit({
                runtimeOp: {
                    type: ContainerMessageType.FluidDataStoreOp, contents: {
                        address: 'dds', contents: {
                            type: 'op', content: text
                        }
                    }
                }, referenceSequenceNumber: ref
            });
        outbox.flush(b.batchId === undefined ? undefined : {
            batchId: b.batchId, staged: false
        });
        ref++;
    }
    pending.dispose();
    return wire;
}
export function inbound(wire: IBatchMessage[][]): unknown[] {
    const processor = new RemoteMessageProcessor(new OpSplitter([], undefined, 256, 10000000, logger), new OpDecompressor(logger), new OpGroupingManager({
        groupedBatchingEnabled: true
    }, logger));
    let seq = 0;
    const results: unknown[] = [];
    for (const batch of wire)
        for (const m of batch) {
            const message: ISequencedDocumentMessage = {
                type: 'op', contents: m.contents === undefined ? undefined : JSON.parse(m.contents), metadata: m.metadata, compression: m.compression, referenceSequenceNumber: m.referenceSequenceNumber ?? 0, clientId: 'sender', clientSequenceNumber: ++seq, sequenceNumber: seq + 100, minimumSequenceNumber: 0, timestamp: 1234
            };
            results.push(processor.process(message, () => {
            }) ?? null);
        }
    return JSON.parse(JSON.stringify(results));
}
