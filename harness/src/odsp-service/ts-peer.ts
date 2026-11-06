// M4 TS peer: real 3.11.0 `OdspClient` containers behind the stdio JSON-RPC interface the Swift
// M4 peer implements (harness/PROTOCOL.md "M4 — ODSP live service"). One process hosts any number
// of client handles; each handle has its own OdspClient, so its own driver factory and caches,
// exactly like a separate app. The multiplexed push socket is shared per process, as in the driver.
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { isIDeltaManagerFull } from '@fluidframework/container-definitions/internal';
import type { IContainer } from '@fluidframework/container-definitions/internal';
import { isInternalFluidContainer } from '@fluidframework/fluid-static/internal';
import { getPresenceAlpha } from '@fluidframework/fluid-static/alpha';
import { isFluidHandle } from '@fluidframework/runtime-utils/internal';
import { StateFactory } from '@fluid-internal/presence-runtime/states';
import { m4Client, m4Schema, mapEntries, type M4Container, type PeerEvent } from './m4-client.js';

/** The one presence value each client publishes (workspace `m4:state`, key `value`). */
const presenceValueSchema = z.object({ by: z.string(), n: z.number() });
type PresenceValue = z.infer<typeof presenceValueSchema>;

function joinPresence(container: M4Container) {
  const presence = getPresenceAlpha(container);
  const workspace = presence.states.getWorkspace('m4:state', {
    value: StateFactory.latest<PresenceValue | null>({ local: null }),
  });
  return { presence, workspace };
}

interface Handle {
  readonly container: M4Container;
  readonly inner: IContainer;
  readonly events: PeerEvent[];
  readonly presence: ReturnType<typeof joinPresence>;
}

const handles = new Map<string, Handle>();

function handle(client: string): Handle {
  const found = handles.get(client);
  if (found === undefined) {
    throw new Error(`unknown client ${client}`);
  }
  return found;
}

function deltaManager(inner: IContainer) {
  const manager = inner.deltaManager;
  if (!isIDeltaManagerFull(manager)) {
    throw new Error('delta manager has no inbound queue');
  }
  return manager;
}

const openSchema = z.object({ client: z.string(), siteUrl: z.string(), driveId: z.string(), itemId: z.string(), user: z.string() });
const clientSchema = z.object({ client: z.string() });
const setSchema = z.object({ client: z.string(), key: z.string(), value: z.unknown() });
const keySchema = z.object({ client: z.string(), key: z.string() });
const insertSchema = z.object({ client: z.string(), pos: z.number().int().nonnegative(), text: z.string() });
const removeSchema = z.object({ client: z.string(), start: z.number().int().nonnegative(), end: z.number().int().nonnegative() });
const blobSchema = z.object({ client: z.string(), key: z.string(), text: z.string() });
const presenceSetSchema = z.object({ client: z.string(), value: presenceValueSchema });

async function open(params: unknown): Promise<null> {
  const request = openSchema.parse(params);
  if (handles.has(request.client)) {
    throw new Error(`client ${request.client} already open`);
  }
  const events: PeerEvent[] = [];
  const odsp = m4Client(request.siteUrl, request.driveId, request.user, events);
  const { container } = await odsp.getContainer(request.itemId, m4Schema, '2.0.0');
  if (!isInternalFluidContainer(container)) {
    throw new Error('container is not internal');
  }
  handles.set(request.client, { container, inner: container.container, events, presence: joinPresence(container) });
  return null;
}

function view(params: unknown) {
  const { container, inner } = handle(clientSchema.parse(params).client);
  const manager = deltaManager(inner);
  return {
    connected: inner.connectionState === 2,
    clientId: inner.clientId ?? null,
    sequenceNumber: manager.lastSequenceNumber,
    initialSequenceNumber: manager.initialSequenceNumber,
    pending: inner.isDirty,
    map: mapEntries(container),
    text: container.initialObjects.text.getText(),
  };
}

function textInsert(params: unknown): null {
  const request = insertSchema.parse(params);
  const text = handle(request.client).container.initialObjects.text;
  text.insertText(Math.min(request.pos, text.getLength()), request.text);
  return null;
}

function textRemove(params: unknown): null {
  const request = removeSchema.parse(params);
  const text = handle(request.client).container.initialObjects.text;
  const start = Math.min(request.start, text.getLength());
  const end = Math.min(request.end, text.getLength());
  if (start < end) {
    text.removeText(start, end);
  }
  return null;
}

/** Uploads UTF-8 bytes as an attachment blob and stores its handle in the map. */
async function blobUpload(params: unknown): Promise<null> {
  const request = blobSchema.parse(params);
  const { container } = handle(request.client);
  const bytes = new TextEncoder().encode(request.text);
  const blob = await container.uploadBlob(bytes.buffer);
  container.initialObjects.map.set(request.key, blob);
  return null;
}

/** Reads the attachment blob whose handle is stored under `key`. */
async function blobRead(params: unknown): Promise<string> {
  const request = keySchema.parse(params);
  const value: unknown = handle(request.client).container.initialObjects.map.get(request.key);
  if (!isFluidHandle(value)) {
    throw new Error(`map key ${request.key} holds no handle`);
  }
  const bytes = z.instanceof(ArrayBuffer).parse(await value.get());
  return new TextDecoder().decode(bytes);
}

/** The local attendee and every remote attendee's latest published value. */
function presenceView(params: unknown) {
  const { presence } = handle(clientSchema.parse(params).client);
  const remotes = [...presence.workspace.states.value.getRemotes()].map(remote => ({
    attendee: remote.attendee.attendeeId,
    connected: remote.attendee.getConnectionStatus() === 'Connected',
    value: remote.value,
  }));
  return { attendee: presence.presence.attendees.getMyself().attendeeId, remotes };
}

async function dispatch(method: string, params: unknown): Promise<unknown> {
  switch (method) {
    case 'open':
      return open(params);
    case 'view':
      return view(params);
    case 'mapSet': {
      const request = setSchema.parse(params);
      handle(request.client).container.initialObjects.map.set(request.key, request.value);
      return null;
    }
    case 'mapDelete': {
      const request = keySchema.parse(params);
      handle(request.client).container.initialObjects.map.delete(request.key);
      return null;
    }
    case 'textInsert':
      return textInsert(params);
    case 'textRemove':
      return textRemove(params);
    case 'disconnect':
      handle(clientSchema.parse(params).client).inner.disconnect();
      return null;
    case 'connect':
      handle(clientSchema.parse(params).client).inner.connect();
      return null;
    case 'pauseInbound':
      await deltaManager(handle(clientSchema.parse(params).client).inner).inbound.pause();
      return null;
    case 'resumeInbound':
      deltaManager(handle(clientSchema.parse(params).client).inner).inbound.resume();
      return null;
    case 'events':
      return handle(clientSchema.parse(params).client).events;
    case 'blobUpload':
      return blobUpload(params);
    case 'blobRead':
      return blobRead(params);
    case 'presenceSet': {
      const request = presenceSetSchema.parse(params);
      handle(request.client).presence.workspace.states.value.local = request.value;
      return null;
    }
    case 'presence':
      return presenceView(params);
    case 'close': {
      const client = clientSchema.parse(params).client;
      handle(client).inner.dispose();
      handles.delete(client);
      return null;
    }
    default:
      throw new Error(`unknown method ${method}`);
  }
}

const requestSchema = z.object({ jsonrpc: z.literal('2.0'), id: z.number(), method: z.string(), params: z.unknown() });

const lines = createInterface({ input: process.stdin });
// Requests are serialized: the harness waits for each response before the next request.
for await (const line of lines) {
  const request = requestSchema.parse(JSON.parse(line));
  try {
    const result = await dispatch(request.method, request.params);
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
  } catch (error) {
    const message = error instanceof Error ? `${error.message}\n${error.stack ?? ''}` : String(error);
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { message } }) + '\n');
  }
}
for (const { inner } of handles.values()) {
  inner.dispose();
}
// The TS summarizer leaves race timers alive after disposal; all owned resources are closed.
process.exit(0);
