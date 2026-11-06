import { setEntropyContext } from '../entropy.js';
import { createHash } from 'node:crypto';
import type { IBatchMessage } from '@fluidframework/container-definitions/internal';
import type { ISequencedDocumentMessage } from '@fluidframework/driver-definitions/internal';
import { IdCompressor } from '../../node_modules/@fluidframework/id-compressor/lib/idCompressor.js';
import { assertIsSessionId } from '../../node_modules/@fluidframework/id-compressor/lib/utilities.js';
import { PendingStateManager, type IPendingLocalState } from '../../node_modules/@fluidframework/container-runtime/lib/pendingStateManager.js';
import { Outbox } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/outbox.js';
import { OpGroupingManager } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opGroupingManager.js';
import { OpCompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opCompressor.js';
import { OpSplitter } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opSplitter.js';
import { OpDecompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opDecompressor.js';
import { RemoteMessageProcessor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/remoteMessageProcessor.js';
import { DuplicateBatchDetector } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/duplicateBatchDetector.js';
import { ContainerMessageType } from '../../node_modules/@fluidframework/container-runtime/lib/messageTypes.js';
import { CompressionAlgorithms } from '../../node_modules/@fluidframework/container-runtime/lib/compressionDefinitions.js';
import type { LocalBatchMessage } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/definitions.js';
const logger = { send: () => {} };
export interface RuntimeScenario {
    runtime: true;
    seed: number;
    uuids: string[];
    commands: { kind: 'submit' | 'disconnect' | 'connect' | 'deliver' | 'drop' | 'duplicate' | 'reload'; client: number; count: number; ids: number; rebase: number }[];
}
export function entropy(seed: number): string[] {
    return Array.from({ length: 256 }, (_, index) => {
        const bytes = createHash('sha256').update(`h3:${seed}:${index}`).digest();
        bytes[6] = ((bytes[6] ?? 0) & 15) | 64;
        bytes[8] = ((bytes[8] ?? 0) & 63) | 128;
        const hex = bytes.subarray(0, 16).toString('hex');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    });
}
class Client {
    connected = true;
    generation = 0;
    csn = 0;
    ref = 0;
    rebase = 0;
    clientId: string;
    pending: PendingStateManager;
    outbox: Outbox;
    compressor: IdCompressor;
    detector = new DuplicateBatchDetector(undefined);
    processor = new RemoteMessageProcessor(new OpSplitter([], undefined, 100000, 1000000, logger), new OpDecompressor(logger), new OpGroupingManager({ groupedBatchingEnabled: true }, logger));
    constructor(readonly index: number, send: (client: Client, batch: IBatchMessage[]) => void, stash?: IPendingLocalState, compressor?: IdCompressor) {
        this.clientId = `client${index}-0`;
        this.compressor = compressor ?? new IdCompressor(assertIsSessionId(`${index + 1}0000000-0000-4000-8000-000000000001`), undefined, 2);
        this.pending = new PendingStateManager({
            connected: () => this.connected,
            clientId: () => this.clientId,
            isActiveConnection: () => true,
            isAttached: () => true,
            applyStashedOp: async content => JSON.parse(content).type === ContainerMessageType.IdAllocation ? undefined : ({ applied: content }),
            reSubmitBatch: (batch, metadata) => {
                for (const message of batch) {
                    if (message.runtimeOp.type === ContainerMessageType.IdAllocation) continue;
                    let runtimeOp = message.runtimeOp;
                    if (runtimeOp.type === ContainerMessageType.FluidDataStoreOp && this.rebase !== 0) {
                        runtimeOp = { ...runtimeOp, contents: { ...runtimeOp.contents, contents: { type: 'op', content: this.rebase } } };
                    }
                    this.outbox.submit({ runtimeOp, referenceSequenceNumber: this.ref, localOpMetadata: message.localOpMetadata });
                }
                this.outbox.flush(metadata);
            },
        }, stash, logger);
        const submit = (batch: IBatchMessage[]) => {
            send(this, structuredClone(batch));
            this.csn += batch.length;
            return this.csn;
        };
        this.outbox = new Outbox({
            shouldSend: () => this.connected,
            pendingStateManager: this.pending,
            submitBatchFn: submit,
            legacySendBatchFn: () => { throw Error('legacy'); },
            config: { compressionOptions: { minimumBatchSizeInBytes: Infinity, compressionAlgorithm: CompressionAlgorithms.lz4 }, maxBatchSizeInBytes: 1000000 },
            compressor: new OpCompressor(logger),
            splitter: new OpSplitter([], submit, 100000, 1000000, logger),
            groupingManager: new OpGroupingManager({ groupedBatchingEnabled: true }, logger),
            logger,
            getCurrentSequenceNumbers: () => ({ referenceSequenceNumber: this.ref, clientSequenceNumber: this.csn }),
            reSubmit: () => { throw Error('unexpected reentrant rebase'); },
            opReentrancy: () => false,
            generateIdAllocationOp: (): LocalBatchMessage | undefined => {
                const range = this.compressor.takeNextCreationRange();
                return range.ids === undefined ? undefined : { runtimeOp: { type: ContainerMessageType.IdAllocation, contents: range }, referenceSequenceNumber: this.ref };
            },
        });
    }
}
export async function runRuntime(s: RuntimeScenario): Promise<string> {
    setEntropyContext(`h3:${s.seed}`);
    const output: unknown[] = [];
    const queue: ISequencedDocumentMessage[][] = [];
    let sequence = 0;
    const send = (client: Client, batch: IBatchMessage[]) => {
        output.push({ wire: batch, clientId: client.clientId });
        queue.push(batch.map((message, index) => ({
            type: 'op', contents: message.contents === undefined ? undefined : JSON.parse(message.contents),
            metadata: message.metadata, compression: message.compression,
            referenceSequenceNumber: message.referenceSequenceNumber ?? 0,
            clientId: client.clientId, clientSequenceNumber: client.csn + index + 1,
            sequenceNumber: 0, minimumSequenceNumber: 0, timestamp: 0,
        })));
    };
    const clients = [new Client(0, send), new Client(1, send), new Client(2, send)];
    let last: ISequencedDocumentMessage[] = [];
    for (const command of s.commands) {
        const selected = clients[command.client];
        if (!selected) throw Error('client');
        let client: Client = selected;
        switch (command.kind) {
            case 'submit': {
                const ids = Array.from({ length: command.ids }, () => {
                    const id = client.compressor.generateCompressedId();
                    return { id, stable: client.compressor.decompress(id) };
                });
                output.push({ ids });
                for (let index = 0; index < command.count; index++) {
                    client.outbox.submit({ runtimeOp: { type: ContainerMessageType.FluidDataStoreOp, contents: { address: 'dds', contents: { type: 'op', content: index + command.rebase } } }, referenceSequenceNumber: client.ref });
                }
                client.outbox.flush();
                break;
            }
            case 'disconnect': client.connected = false; break;
            case 'connect':
                client.connected = true;
                client.clientId = `client${client.index}-${++client.generation}`;
                client.csn = 0;
                client.rebase = command.rebase;
                client.compressor.resetUnfinalizedCreationRange();
                client.pending.replayPendingStates();
                break;
            case 'drop': queue.splice(0); break;
            case 'reload': {
                const state = client.pending.getLocalState(client.ref);
                const serialized = client.compressor.serialize(true);
                output.push(structuredClone({ stash: { ...state, pendingIdCompressorState: serialized } }));
                const compressor = IdCompressor.deserialize({ serialized, requestedWriteVersion: 2 });
                const loaded = new Client(client.index, send, state.pending, compressor);
                loaded.clientId = client.clientId;
                loaded.ref = client.ref;
                loaded.generation = client.generation;
                loaded.connected = false;
                await loaded.pending.applyStashedOpsAt();
                clients[command.client] = loaded;
                client = loaded;
                break;
            }
            case 'duplicate':
            case 'deliver': {
                const batches = command.kind === 'duplicate' ? [last] : queue.splice(0);
                for (const batch of batches) {
                    if (command.kind === 'deliver') {
                        for (const message of batch) message.sequenceNumber = ++sequence;
                        last = batch;
                    }
                    for (const receiver of clients) {
                        for (const message of batch) {
                            receiver.ref = Math.max(receiver.ref, message.sequenceNumber);
                            const inbound = receiver.processor.process(structuredClone(message), () => {});
                            if (!inbound) continue;
                            if ('batchStart' in inbound && receiver.detector.processInboundBatch(inbound.batchStart).duplicate) {
                                output.push({ client: receiver.index, classification: 'duplicate' });
                                continue;
                            }
                            const local = receiver.clientId === message.clientId;
                            const processed = receiver.pending.processInboundMessages(inbound, local);
                            for (const entry of processed) {
                                if (entry.message.type === ContainerMessageType.IdAllocation) receiver.compressor.finalizeCreationRange(entry.message.contents);
                            }
                            output.push({ client: receiver.index, classification: local ? 'local' : 'remote', processed });
                        }
                    }
                }
                break;
            }
        }
        output.push(clients.map(c => ({ count: c.pending.pendingMessagesCount, dirty: c.pending.hasPendingUserChanges(), state: c.pending.getLocalState(), compressor: c.compressor.serialize(true) })));
    }
    return JSON.stringify(output);
}
