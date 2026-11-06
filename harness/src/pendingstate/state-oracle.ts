import '../entropy.js';
import assert from 'node:assert/strict';
import { PendingStateManager } from '../../node_modules/@fluidframework/container-runtime/lib/pendingStateManager.js';
import { ContainerMessageType } from '../../node_modules/@fluidframework/container-runtime/lib/messageTypes.js';
export async function stateCheckpoint(): Promise<string> {
    const manager = new PendingStateManager({
        connected: () => true,
        clientId: () => 'a',
        isActiveConnection: () => true,
        isAttached: () => true,
        applyStashedOp: async () => undefined,
        reSubmitBatch: () => { throw Error('unexpected replay'); },
    }, undefined, { send: () => {} });
    manager.onFlushBatch([{
        runtimeOp: { type: ContainerMessageType.FluidDataStoreOp, contents: { address: 'dds', contents: { type: 'op', content: 'hello' } } },
        referenceSequenceNumber: 0,
    }], 1, false);
    return JSON.stringify(manager.getLocalState());
}
export async function replayCheckpoint(): Promise<string> {
    let client = 'a';
    const replay: unknown[] = [];
    const manager = new PendingStateManager({
        connected: () => true,
        clientId: () => client,
        isActiveConnection: () => true,
        isAttached: () => true,
        applyStashedOp: async content => ({ applied: content }),
        reSubmitBatch: (batch, metadata) => { replay.push({ batch, metadata }); },
    }, undefined, { send: () => {} });
    manager.onFlushBatch([{ runtimeOp: { type: ContainerMessageType.Rejoin, contents: undefined }, referenceSequenceNumber: 0 }], 1, false);
    client = 'b';
    manager.replayPendingStates();
    return JSON.stringify(replay);
}

export async function checkStateCheckpoints(): Promise<void> {
    const content = JSON.stringify({ type: 'component', contents: { address: 'dds', contents: { type: 'op', content: 'hello' } } });
    assert.equal(await stateCheckpoint(), JSON.stringify({ pending: { pendingStates: [{
        type: 'message', referenceSequenceNumber: 0, content,
        batchInfo: { clientId: 'a', batchStartCsn: 1, length: 1, staged: false },
    }] } }));
    assert.equal(await replayCheckpoint(), '[{"batch":[{"runtimeOp":{"type":"rejoin"}}],"metadata":{"batchId":"a_[1]","staged":false,"squash":false}}]');
}
