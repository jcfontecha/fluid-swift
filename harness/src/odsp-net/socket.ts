import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Server } from 'socket.io';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { OdspDocumentDeltaConnection } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDocumentDeltaConnection.js';
import { EpochTracker } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
import type { IClient } from '@fluidframework/driver-definitions';
export const socketClient: IClient = { mode: 'write', details: { capabilities: { interactive: true }, environment: 'harness' }, permission: [], user: { id: 'user' }, scopes: [] };
export function socketFake(io: Server): {
    reset(): void;
    finish(count: number): Promise<string[]>;
} {
    let trace: string[] = [];
    let disconnects = 0;
    let done: (() => void) | undefined;
    let target = 0;
    io.on('connection', socket => {
        let flushCount = 0;
        trace.push('transport');
        socket.onAny((name: string, ...args: unknown[]) => {
            trace.push(JSON.stringify([name, ...args]).replace(/[0-9a-f]{8}-[0-9a-f-]{27}-([0-9]+)/gi, 'NONCE-$1'));
            if (name === 'disconnect_document') {
                disconnects++;
                if (disconnects === target)
                    done?.();
            }
        });
        socket.on('connect_document', (message: {
            id: string;
            nonce: string;
            mode: string;
        }) => {
            if (message.id.startsWith('error')) {
                socket.emit('connect_document_error', { code: Number(message.id.slice(5)), message: 'failure', nonce: message.nonce });
                return;
            }
            socket.emit('connect_document_success', { nonce: 'wrong-nonce' });
            socket.emit('op', 'foreign', [{ sequenceNumber: 99 }]);
            socket.emit('op', message.id, [{ sequenceNumber: 3 }, { sequenceNumber: 2 }]);
            socket.emit('signal', { clientId: null, content: 'early' }, message.id);
            socket.emit('connect_document_success', { ...message, clientId: 'client-' + message.id, mode: message.id === 'badmode' ? 'read' : message.mode, claims: { scopes: ['doc:write'] }, initialMessages: [{ sequenceNumber: 1 }], initialSignals: [], supportedFeatures: { api_get_ops: true, api_flush_ops: true }, epoch: 'E' });
        });
        socket.on('submitOp', (client: string) => {
            const doc = client.slice(7);
            socket.emit('op', 'other', [{ sequenceNumber: 99 }]);
            socket.emit('op', doc, [{ sequenceNumber: 4 }]);
            socket.emit('signal', [{ clientId: null, content: 'broadcast' }, { clientId: null, content: 'private', targetClientId: client }, { clientId: null, content: 'wrong', targetClientId: 'other' }], doc);
            socket.emit('nack', 'other', []);
            socket.emit('nack', client, []);
        });
        socket.on('get_ops', (_client: string, request: {
            nonce: string;
        }) => {
            socket.emit('get_ops_response', { nonce: 'other-1', code: 200, messages: [{ sequenceNumber: 99 }] });
            socket.emit('get_ops_response', { nonce: request.nonce, code: 204, messages: [{ sequenceNumber: 5 }] });
        });
        socket.on('flush_ops', (client: string, request: {
            nonce: string;
        }) => {
            if (client === 'client-overlap' && ++flushCount === 1)
                return;
            if (client === 'client-disconnect' || client === 'client-session') {
                socket.emit('server_disconnect', { code: 403, message: 'forbidden' }, client);
                return;
            }
            socket.emit('flush_ops_response', { nonce: request.nonce, code: 200, lastPersistedSequenceNumber: 5 });
        });
    });
    return {
        reset() { trace = []; disconnects = 0; done = undefined; },
        async finish(count) {
            target = count;
            if (disconnects < count)
                await new Promise<void>(resolve => { done = resolve; });
            return [...trace];
        },
    };
}
export async function socketOracle(url: string, documentId = 'doc'): Promise<unknown> {
    const logger = new MockLogger().toTelemetryLogger();
    const resolvedUrl = await new OdspDriverUrlResolver().resolve({ url: url + '?driveId=d&itemId=i&path=' });
    const epoch = new EpochTracker({ get: async () => undefined, put: async () => { }, removeEntries: async () => { } }, { docId: 'doc', resolvedUrl }, logger, false);
    const prefix = randomUUID();
    const events: unknown[] = [];
    const connections: OdspDocumentDeltaConnection[] = [];
    try {
        if (documentId === 'parallel') {
            const created = await Promise.all(['parallel-first', 'parallel-second'].map(id => OdspDocumentDeltaConnection.create('tenant', id, 'token', socketClient, url, logger, 60000, epoch, prefix, 'nonce-' + id)));
            for (const connection of created) {
                connection.on('op', () => { });
                connection.on('signal', () => { });
                connection.on('disconnect', () => events.push(['disconnect', connection.clientId.slice(7)]));
                events.push(['initial', connection.initialMessages, connection.initialSignals]);
            }
            for (const connection of created)
                connection.dispose();
            return { events };
        }
        for (const id of [documentId, 'second']) {
            const connection = await OdspDocumentDeltaConnection.create('tenant', id, 'token', socketClient, url, logger, 60000, epoch, prefix, 'nonce-' + id);
            connections.push(connection);
            connection.on('op', (_doc, ops) => events.push(['op', ops]));
            connection.on('signal', signal => events.push(['signal', signal]));
            connection.on('nack', (_id, nacks) => events.push(['nack', nacks]));
            connection.on('disconnect', () => events.push(['disconnect', id]));
            events.push(['initial', connection.initialMessages, connection.initialSignals]);
        }
        const first = connections[0];
        assert(first);
        first.submit([]);
        first.submitSignal('outgoing', 'target');
        first.requestOps(1, 6);
        if (documentId === 'overlap') {
            const result = await Promise.allSettled([first.flush(), first.flush()]);
            const values = result.map(item => item.status === 'fulfilled'
                ? { ok: true } : { error: String(item.reason) });
            for (const connection of connections)
                connection.dispose();
            return values.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
        }
        const result = await first.flush();
        events.push(['flush', { ...result, nonce: 'NONCE-2' }]);
        for (const connection of connections)
            connection.dispose();
        const reused = await OdspDocumentDeltaConnection.create('tenant', 'reused', 'token', socketClient, url, logger, 60000, epoch, prefix, 'nonce-reused');
        reused.on('op', () => { });
        reused.on('signal', () => { });
        reused.on('disconnect', () => events.push(['disconnect', 'reused']));
        events.push(['initial', reused.initialMessages, reused.initialSignals]);
        reused.dispose();
        await new Promise<void>(resolve => setTimeout(resolve, 2100));
        const evicted = await OdspDocumentDeltaConnection.create('tenant', 'evicted', 'token', socketClient, url, logger, 60000, epoch, prefix, 'nonce-evicted');
        evicted.on('op', () => { });
        evicted.on('signal', () => { });
        evicted.on('disconnect', () => events.push(['disconnect', 'evicted']));
        events.push(['initial', evicted.initialMessages, evicted.initialSignals]);
        evicted.dispose();
        return { events };
    }
    catch (error) {
        for (const connection of connections)
            connection.dispose();
        const fields = error as {
            errorType: string;
            canRetry: boolean;
            statusCode: number;
        };
        return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode };
    }
}
