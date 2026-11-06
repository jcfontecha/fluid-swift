// ODSP push (relay) over Socket.IO, as the 3.11.0 OdspDocumentDeltaConnection speaks it.
//
// The handshake and op/signal handling mirror routerlicious nexus (server-lambdas 7.0.1
// nexus/connect.ts and nexus/index.ts). ODSP differences, all from odspDocumentDeltaConnection.ts
// and driver-base documentDeltaConnection.ts:
// - one physical socket multiplexes documents *and* several clients of one document, so rooms are
//   reference counted per socket and every reply carries the connection `nonce`;
// - `signal` is emitted as `(signal, documentId)` (assert 0xa65 requires the document id);
// - `nack` names the client (`(clientId, nacks)`) so sibling connections on the socket ignore it;
// - `get_ops` / `flush_ops` (features `api_get_ops`, `api_flush_ops`) are served from the
//   persisted op stream; single-commit summaries require flush (odspDocumentStorageManager.ts);
// - `connect_document_success` carries `epoch` (EpochTracker.validateEpoch, assert 0x584) and
//   `checkpointSequenceNumber`.
import type { Server, Socket } from 'socket.io';
import { z } from 'zod';
import { NackErrorType, ScopeType } from '@fluidframework/driver-definitions/internal';
import type { IClient, IConnected, IDocumentMessage, ISignalClient, ITokenClaims } from '@fluidframework/driver-definitions/internal';
import { createNackMessage, createRoomJoinMessage, createRoomLeaveMessage, generateClientId } from '@fluidframework/server-lambdas';
import { DefaultServiceConfiguration } from '@fluidframework/server-services-core';
import type { IOrdererConnection } from '@fluidframework/server-services-core';
import type { ISubscriber } from '@fluidframework/server-memory-orderer';
import { serverFailures, type OdspSession } from './ordering.js';
import { userFromToken } from './tokens.js';

/** nexus/protocol.ts ProtocolVersions. */
const protocolVersions = ['^0.4.0', '^0.3.0', '^0.2.0', '^0.1.0'];
const scopes = [ScopeType.DocRead, ScopeType.DocWrite, ScopeType.SummaryWrite];

const clientSchema = z.looseObject({
  details: z.looseObject({
    capabilities: z.looseObject({ interactive: z.boolean() }),
    type: z.string().optional(),
    environment: z.string().optional(),
    device: z.string().optional(),
  }),
  permission: z.array(z.string()),
  scopes: z.array(z.string()),
  user: z.looseObject({ id: z.string() }),
  mode: z.enum(['write', 'read']),
  timestamp: z.number().optional(),
});
/** odspDocumentDeltaConnection.ts create(): the exact IConnect the 3.11.0 driver emits. */
const connectSchema = z.strictObject({
  client: clientSchema,
  id: z.string(),
  mode: z.enum(['write', 'read']),
  tenantId: z.string(),
  token: z.string().nullable(),
  versions: z.array(z.string()),
  driverVersion: z.string(),
  nonce: z.string(),
  epoch: z.string().optional(),
  relayUserAgent: z.string(),
  supportedFeatures: z.record(z.string(), z.unknown()),
});
const documentMessageSchema = z.looseObject({
  clientSequenceNumber: z.number().int(),
  referenceSequenceNumber: z.number().int(),
  type: z.string(),
  // Noops are submitted with undefined contents, which Socket.IO's JSON drops.
  contents: z.unknown().optional(),
  metadata: z.unknown().optional(),
  traces: z.array(z.object({ service: z.string(), action: z.string(), timestamp: z.number() })).optional(),
  compression: z.string().optional(),
});
const submitOpSchema = z.array(z.array(documentMessageSchema));
/** nexus/utils.ts isSentSignalMessage, v2 format (ODSP always sends v2). */
const sentSignalSchema = z.strictObject({
  content: z.unknown(),
  type: z.string().optional(),
  clientConnectionNumber: z.number().optional(),
  referenceSequenceNumber: z.number().optional(),
  targetClientId: z.string().optional(),
});
const getOpsSchema = z.strictObject({ nonce: z.string(), from: z.number().int(), to: z.number().int() });
const flushSchema = z.strictObject({ nonce: z.string() });

interface PushClient {
  readonly clientId: string;
  readonly session: OdspSession;
  readonly socket: Socket;
  readonly client: IClient;
  /** Writers have an orderer connection; readers only receive. */
  readonly connection: IOrdererConnection | undefined;
  readonly nackSubscriber: ISubscriber;
}

function documentRoom(session: OdspSession): string {
  return `${session.tenantId}/${session.file.documentId}`;
}

function clientRoom(clientId: string): string {
  return `client#${clientId}`;
}

/** nexus/utils.ts isSummarizer. */
function isSummarizer(client: z.infer<typeof clientSchema>): boolean {
  return client.details.type === 'summarizer' || client.details.capabilities.interactive === false;
}

export class OdspPush {
  /** How often each push event was handled or emitted; the harness reports surface coverage from it. */
  readonly counts = new Map<string, number>();
  private readonly clients = new Map<string, PushClient>();
  /** Per socket, how many connected clients use each document room. */
  private readonly roomCounts = new Map<string, Map<string, number>>();
  /** Per socket: connect_document requests being answered, and when the last one was answered. */
  private readonly handshakes = new Map<string, { pending: number; lastAnswered: number }>();
  private readonly roomSubscribers = new Set<string>();

  constructor(
    private readonly io: Server,
    private readonly sessionFor: (tenantId: string, documentId: string) => OdspSession | undefined,
  ) {
    io.on('connection', socket => this.attach(socket));
  }

  private count(event: string): void {
    this.counts.set(event, (this.counts.get(event) ?? 0) + 1);
  }

  private attach(socket: Socket): void {
    this.roomCounts.set(socket.id, new Map());
    socket.onAny((event: string) => this.count(event));
    const handshake = { pending: 0, lastAnswered: 0 };
    this.handshakes.set(socket.id, handshake);
    socket.on('connect_document', (message: unknown) => {
      handshake.pending++;
      this.connectDocument(socket, message)
        .catch((error: unknown) => {
          serverFailures.push(`connect_document: ${error instanceof Error ? error.stack : String(error)}`);
        })
        .finally(() => {
          handshake.pending--;
          handshake.lastAnswered = Date.now();
        });
    });
    socket.on('submitOp', (clientId: string, batches: unknown) => this.submitOp(socket, clientId, batches));
    socket.on('submitSignal', (clientId: string, signals: unknown) => this.submitSignal(socket, clientId, signals));
    socket.on('get_ops', (clientId: string, request: unknown) => this.getOps(socket, clientId, request));
    socket.on('flush_ops', (clientId: string, request: unknown) => {
      this.flushOps(socket, clientId, request).catch((error: unknown) => {
        serverFailures.push(`flush_ops: ${String(error)}`);
      });
    });
    // driver-base documentDeltaConnection.ts measures latency with a volatile `ping` and its ack.
    socket.on('ping', (acknowledge: unknown) => {
      if (typeof acknowledge !== 'function') {
        serverFailures.push('ping without acknowledgement callback');
        return;
      }
      acknowledge();
    });
    socket.on('disconnect_document', (clientId: string, documentId: string) => {
      const pushClient = this.ownedClient(socket, clientId);
      if (pushClient !== undefined && pushClient.session.file.documentId === documentId) {
        this.removeClient(pushClient);
      }
    });
    socket.on('disconnect', () => {
      for (const pushClient of [...this.clients.values()]) {
        if (pushClient.socket === socket) {
          this.removeClient(pushClient);
        }
      }
      this.roomCounts.delete(socket.id);
      this.handshakes.delete(socket.id);
    });
  }

  private async connectDocument(socket: Socket, raw: unknown): Promise<void> {
    const parsed = connectSchema.safeParse(raw);
    if (!parsed.success) {
      serverFailures.push(`connect_document: invalid message ${parsed.error.message}`);
      socket.emit('connect_document_error', { code: 400, message: 'Invalid connection message' });
      return;
    }
    const message = parsed.data;
    const fail = (code: number, text: string) => {
      socket.emit('connect_document_error', { code, message: text, nonce: message.nonce });
    };
    const version = protocolVersions.find(candidate => message.versions.includes(candidate));
    if (version === undefined) {
      fail(400, `Unsupported client protocol. Client: ${message.versions.join(',')}`);
      return;
    }
    const session = this.sessionFor(message.tenantId, message.id);
    if (session === undefined) {
      fail(404, `Unknown session ${message.tenantId}/${message.id}`);
      return;
    }
    const user = message.token === null ? undefined : userFromToken(message.token, 'push');
    if (user === undefined) {
      fail(401, 'Invalid push token');
      return;
    }
    if (message.epoch !== undefined && message.epoch !== session.file.epoch) {
      fail(409, `Epoch mismatch: ${message.epoch} != ${session.file.epoch}`);
      return;
    }
    const clientId = generateClientId();
    const room = documentRoom(session);
    this.ensureRoomSubscriber(session);
    // Count the room before joining it, so a sibling connection leaving the same document on this
    // socket in the meantime cannot take the socket out of the room.
    this.incrementRoom(socket, room);
    this.roomOperation(socket.join(room), 'join');
    this.roomOperation(socket.join(clientRoom(clientId)), 'join');
    const initialClients = this.connectedClients(session);
    const summarizer = isSummarizer(message.client);
    // nexus createMessageClient: identity and scopes come from the token, not the client.
    const clientScopes = summarizer ? scopes : scopes.filter(scope => scope !== ScopeType.SummaryWrite);
    const writer = message.mode === 'write';
    const client: IClient = {
      ...message.client,
      user,
      mode: writer ? 'write' : 'read',
      scopes: clientScopes,
    };
    const nackSubscriber: ISubscriber = {
      id: clientRoom(clientId),
      send: (_topic: string, event: string, _documentId: string, nacks: unknown) => {
        this.count(`emit ${event}`);
        this.io.to(clientRoom(clientId)).emit(event, clientId, nacks);
      },
    };
    session.pubSub.subscribe(clientRoom(clientId), nackSubscriber);
    // LocalOrdererConnection keeps the subscriber but never publishes through it; delivery goes
    // through the room subscriptions above.
    const connection = writer
      ? session.orderer.connectInternal({ id: clientId, send: () => {} }, clientId, client)
      : undefined;
    if (connection !== undefined) {
      await connection.connect();
    }
    this.clients.set(clientId, { clientId, session, socket, client, connection, nackSubscriber });
    const now = Date.now();
    const claims: ITokenClaims = {
      documentId: session.file.documentId,
      scopes,
      tenantId: session.tenantId,
      user,
      iat: Math.floor(now / 1000),
      exp: Math.floor(now / 1000) + 3600,
      ver: '1.0',
    };
    // nexus composeConnectedMessage: readers get a 1024-byte message size and service defaults.
    const maxMessageSize = connection === undefined ? 1024 : connection.maxMessageSize;
    const configuration = connection === undefined ? DefaultServiceConfiguration : connection.serviceConfiguration;
    const connected: IConnected = {
      claims,
      clientId,
      existing: true,
      maxMessageSize,
      mode: client.mode,
      serviceConfiguration: {
        blockSize: configuration.blockSize,
        maxMessageSize: configuration.maxMessageSize,
      },
      initialClients,
      initialMessages: [],
      initialSignals: [],
      supportedVersions: protocolVersions,
      supportedFeatures: { submit_signals_v2: true, api_get_ops: true, api_flush_ops: true },
      version,
      timestamp: now,
      nonce: message.nonce,
      epoch: session.file.epoch,
      checkpointSequenceNumber: session.lastSequenceNumber,
      relayServiceAgent: 'service:local-odsp',
    };
    socket.emit('connect_document_success', connected);
    this.io.to(room).emit('signal', createRoomJoinMessage(clientId, client), session.file.documentId);
  }

  private submitOp(socket: Socket, clientId: string, raw: unknown): void {
    const pushClient = this.ownedClient(socket, clientId);
    if (pushClient === undefined) {
      socket.emit('nack', clientId, [createNackMessage(400, NackErrorType.BadRequestError, 'Nonexistent client')]);
      return;
    }
    if (pushClient.connection === undefined) {
      socket.emit('nack', clientId, [createNackMessage(400, NackErrorType.BadRequestError, 'Readonly client')]);
      return;
    }
    const batches = submitOpSchema.safeParse(raw);
    if (!batches.success) {
      serverFailures.push(`submitOp: invalid batches ${batches.error.message}`);
      socket.emit('nack', clientId, [createNackMessage(400, NackErrorType.BadRequestError, 'Invalid op batch')]);
      return;
    }
    for (const batch of batches.data) {
      // nexus sanitizeMessage: only these fields reach the orderer.
      const sanitized: IDocumentMessage[] = batch.map(message => ({
        clientSequenceNumber: message.clientSequenceNumber,
        contents: message.contents,
        metadata: message.metadata,
        referenceSequenceNumber: message.referenceSequenceNumber,
        traces: message.traces,
        type: message.type,
        compression: message.compression,
      }));
      if (sanitized.length > 0) {
        pushClient.connection.order(sanitized).catch((error: unknown) => {
          serverFailures.push(`order: ${String(error)}`);
        });
      }
    }
  }

  private submitSignal(socket: Socket, clientId: string, raw: unknown): void {
    const pushClient = this.ownedClient(socket, clientId);
    if (pushClient === undefined) {
      socket.emit('nack', clientId, [createNackMessage(400, NackErrorType.BadRequestError, 'Nonexistent client')]);
      return;
    }
    const signals = z.array(sentSignalSchema).safeParse(raw);
    if (!signals.success) {
      serverFailures.push(`submitSignal: invalid signals ${signals.error.message}`);
      socket.emit('nack', clientId, [createNackMessage(400, NackErrorType.BadRequestError, 'Invalid signal message')]);
      return;
    }
    const documentId = pushClient.session.file.documentId;
    for (const signal of signals.data) {
      const signalMessage = { ...signal, clientId };
      const room = signal.targetClientId === undefined ? documentRoom(pushClient.session) : clientRoom(signal.targetClientId);
      this.io.to(room).emit('signal', signalMessage, documentId);
    }
  }

  private getOps(socket: Socket, clientId: string, raw: unknown): void {
    const pushClient = this.ownedClient(socket, clientId);
    const request = getOpsSchema.safeParse(raw);
    if (pushClient === undefined || !request.success) {
      serverFailures.push(`get_ops: invalid request from ${clientId}`);
      return;
    }
    const messages = pushClient.session.file.opsInRange(request.data.from, request.data.to);
    socket.emit('get_ops_response', { nonce: request.data.nonce, code: 200, messages });
  }

  private async flushOps(socket: Socket, clientId: string, raw: unknown): Promise<void> {
    const pushClient = this.ownedClient(socket, clientId);
    const request = flushSchema.safeParse(raw);
    if (pushClient === undefined || !request.success) {
      serverFailures.push(`flush_ops: invalid request from ${clientId}`);
      return;
    }
    const lastPersistedSequenceNumber = await pushClient.session.flush();
    socket.emit('flush_ops_response', { nonce: request.data.nonce, code: 200, lastPersistedSequenceNumber });
  }

  private ownedClient(socket: Socket, clientId: string): PushClient | undefined {
    const pushClient = this.clients.get(clientId);
    if (pushClient === undefined || pushClient.socket !== socket) {
      return undefined;
    }
    return pushClient;
  }

  private ensureRoomSubscriber(session: OdspSession): void {
    const room = documentRoom(session);
    if (this.roomSubscribers.has(room)) {
      return;
    }
    this.roomSubscribers.add(room);
    session.pubSub.subscribe(room, {
      id: room,
      send: (_topic: string, event: string, documentId: string, messages: unknown) => {
        // The broadcaster publishes sequenced ops as (documentId, messages), the ODSP `op` shape.
        if (event !== 'op') {
          serverFailures.push(`unexpected broadcast event ${event}`);
          return;
        }
        this.io.to(room).emit('op', documentId, messages);
      },
    });
  }

  private incrementRoom(socket: Socket, room: string): void {
    const counts = this.roomCounts.get(socket.id);
    if (counts === undefined) {
      throw new Error(`socket ${socket.id} is not tracked`);
    }
    counts.set(room, (counts.get(room) ?? 0) + 1);
  }

  private connectedClients(session: OdspSession): ISignalClient[] {
    const result: ISignalClient[] = [];
    for (const pushClient of this.clients.values()) {
      if (pushClient.session === session) {
        result.push({ clientId: pushClient.clientId, client: pushClient.client });
      }
    }
    return result;
  }

  /** nexus/disconnect.ts: leave op for writers, leave signal for everyone, then leave the rooms. */
  private removeClient(pushClient: PushClient): void {
    this.clients.delete(pushClient.clientId);
    const room = documentRoom(pushClient.session);
    pushClient.session.pubSub.unsubscribe(clientRoom(pushClient.clientId), pushClient.nackSubscriber);
    if (pushClient.connection !== undefined) {
      pushClient.connection.disconnect().catch((error: unknown) => {
        serverFailures.push(`disconnect: ${String(error)}`);
      });
    }
    this.io.to(room).emit('signal', createRoomLeaveMessage(pushClient.clientId), pushClient.session.file.documentId);
    const counts = this.roomCounts.get(pushClient.socket.id);
    const remaining = (counts?.get(room) ?? 0) - 1;
    this.roomOperation(pushClient.socket.leave(clientRoom(pushClient.clientId)), 'leave');
    if (remaining > 0) {
      counts?.set(room, remaining);
      return;
    }
    counts?.delete(room);
    // Leaving synchronously: a reconnect on the same socket (read -> write upgrade, nack) joins
    // the room again right after, and a deferred leave would drop the new connection's ops.
    this.roomOperation(pushClient.socket.leave(room), 'leave');
  }

  /** socket.io's in-memory adapter joins and leaves synchronously; other adapters return a promise. */
  private roomOperation(result: Promise<void> | void, name: string): void {
    Promise.resolve(result).catch((error: unknown) => {
      serverFailures.push(`${name}: ${String(error)}`);
    });
  }

  /**
   * Fault: push tells one client it was disconnected (`server_disconnect` with its client id).
   * Returns false, injecting nothing, unless the client's socket has had no handshake in flight for
   * 250 ms. In 3.11.0 every connection on the socket evaluates `clientId === this.clientId`
   * (odspDocumentDeltaConnection.ts disconnectHandler), and driver-base's `clientId` getter throws
   * for a connection still in its handshake, crashing the client process.
   */
  serverDisconnect(clientId: string, code: number): boolean {
    const pushClient = this.clients.get(clientId);
    if (pushClient === undefined) {
      throw new Error(`unknown client ${clientId}`);
    }
    const handshake = this.handshakes.get(pushClient.socket.id);
    if (handshake === undefined || handshake.pending > 0 || Date.now() - handshake.lastAnswered < 250) {
      return false;
    }
    pushClient.socket.emit('server_disconnect', { code, message: `Injected server_disconnect ${code}` }, clientId);
    this.removeClient(pushClient);
    return true;
  }

  /**
   * Fault: the ordering service drops a writer (deli's client timeout). The client is not told;
   * its next op is nacked by deli as a nonexistent client, which makes it reconnect.
   */
  evict(clientId: string): void {
    const pushClient = this.clients.get(clientId);
    if (pushClient?.connection === undefined) {
      throw new Error(`unknown writer ${clientId}`);
    }
    pushClient.connection.disconnect().catch((error: unknown) => {
      serverFailures.push(`evict: ${String(error)}`);
    });
  }

  clientIds(documentId: string): string[] {
    const result: string[] = [];
    for (const pushClient of this.clients.values()) {
      if (pushClient.session.file.documentId === documentId) {
        result.push(pushClient.clientId);
      }
    }
    return result;
  }
}
