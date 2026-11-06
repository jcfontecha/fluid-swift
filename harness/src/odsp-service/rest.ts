// SharePoint REST surface used by the 3.11.0 ODSP driver, rooted at `<origin>/_api/v2.1`
// (odspUrlHelper.ts getApiRoot). Every route, query, header and body shape is the one the driver
// emits; see specs/odsp-driver/{urls,snapshots-cache,session-ops,summaries,lifecycle-history}.md.
//
// UMP requests (`?ump=1`, odspUtils.ts / epochTracker.ts addParamInBody) carry their headers inside a
// `multipart/form-data` body: `--B`, header lines, `_post: 1`, an optional JSON body, `--B--`.
import type { IncomingMessage, ServerResponse } from 'node:http';
import { z } from 'zod';
import { OdspHttpError, summaryPayloadSchema, type OdspDrive, type OdspFile } from './store.js';
import { serverFailures, type OdspSession } from './ordering.js';
import { userFromToken, type OdspUser } from './tokens.js';

/** One HTTP exchange as the driver saw it; the harness checks the endpoint set and that none failed. */
export interface RestRecord {
  readonly method: string;
  readonly route: string;
  readonly status: number;
  readonly error?: string;
}

export interface RestContext {
  readonly drive: OdspDrive;
  readonly tenantId: string;
  session(file: OdspFile): OdspSession;
  createSession(file: OdspFile): Promise<OdspSession>;
}

interface ParsedRequest {
  readonly method: string;
  readonly url: URL;
  /** Effective headers: HTTP headers, or the UMP envelope's lines for `ump=1`. Names are lower case. */
  readonly headers: Map<string, string[]>;
  readonly body: Buffer;
  readonly origin: string;
}

interface Reply {
  readonly status: number;
  readonly body: Buffer | object;
  readonly contentType?: string;
  readonly headers?: Record<string, string>;
}

const joinBodySchema = z.strictObject({ requestSocketToken: z.literal(true).optional(), displayName: z.string().optional() });
const renameSchema = z.strictObject({ name: z.string() });
const umpPost = '_post: 1\r\n';

function header(request: ParsedRequest, name: string): string | undefined {
  const values = request.headers.get(name);
  if (values === undefined) {
    return undefined;
  }
  if (values.length !== 1) {
    throw new OdspHttpError(400, 'invalidRequest', `header ${name} repeated`);
  }
  return values[0];
}

function parseUmp(contentType: string | undefined, body: string): { headers: Map<string, string[]>; body: string } {
  const match = /^multipart\/form-data;boundary=([0-9a-f-]+)$/.exec(contentType ?? '');
  if (match?.[1] === undefined) {
    throw new OdspHttpError(400, 'invalidRequest', `UMP request content-type ${contentType}`);
  }
  const start = `--${match[1]}\r\n`;
  const end = `\r\n--${match[1]}--`;
  if (!body.startsWith(start) || !body.endsWith(end)) {
    throw new OdspHttpError(400, 'invalidRequest', 'UMP body is not framed by its boundary');
  }
  const inner = body.slice(start.length, body.length - end.length);
  const marker = inner.indexOf(umpPost);
  if (marker < 0) {
    throw new OdspHttpError(400, 'invalidRequest', 'UMP body has no _post line');
  }
  const headers = new Map<string, string[]>();
  for (const line of inner.slice(0, marker).split('\r\n').filter(text => text.length > 0)) {
    const colon = line.indexOf(': ');
    if (colon <= 0) {
      throw new OdspHttpError(400, 'invalidRequest', `UMP header line ${JSON.stringify(line)}`);
    }
    const name = line.slice(0, colon).toLowerCase();
    headers.set(name, [...(headers.get(name) ?? []), line.slice(colon + 2)]);
  }
  const rest = inner.slice(marker + umpPost.length);
  if (rest.length === 0) {
    return { headers, body: '' };
  }
  // `\r\n<json>\r\n`: vroom.ts and createNewUtils.ts both wrap the JSON in blank lines.
  if (!rest.startsWith('\r\n') || !rest.endsWith('\r\n')) {
    throw new OdspHttpError(400, 'invalidRequest', 'UMP JSON body is not delimited');
  }
  return { headers, body: rest.slice(2, -2) };
}

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

function httpHeaders(request: IncomingMessage): Map<string, string[]> {
  const headers = new Map<string, string[]>();
  for (const [name, value] of Object.entries(request.headers)) {
    if (value === undefined) {
      continue;
    }
    headers.set(name, Array.isArray(value) ? value : [value]);
  }
  return headers;
}

/** Turns a Node request into the driver's logical request, unwrapping UMP. */
async function parseRequest(request: IncomingMessage): Promise<ParsedRequest> {
  const host = request.headers.host;
  if (host === undefined) {
    throw new OdspHttpError(400, 'invalidRequest', 'missing Host');
  }
  const origin = `http://${host}`;
  const url = new URL(request.url ?? '/', origin);
  const body = await readBody(request);
  if (url.searchParams.get('ump') !== '1') {
    return { method: request.method ?? 'GET', url, headers: httpHeaders(request), body, origin };
  }
  if (request.method !== 'POST') {
    throw new OdspHttpError(400, 'invalidRequest', 'UMP requests are POSTs');
  }
  const ump = parseUmp(request.headers['content-type'], body.toString('utf8'));
  const override = ump.headers.get('x-http-method-override');
  if (override?.length !== 1 || override[0] === undefined) {
    throw new OdspHttpError(400, 'invalidRequest', 'UMP request without X-HTTP-Method-Override');
  }
  const headers = ump.headers;
  // The real transport headers still apply (accept is sent outside the envelope).
  for (const [name, values] of httpHeaders(request)) {
    if (!headers.has(name) && name !== 'content-type') {
      headers.set(name, values);
    }
  }
  return { method: override[0], url, headers, body: Buffer.from(ump.body, 'utf8'), origin };
}

/** Storage token and correlation header, required on every driver REST call (epochTracker.ts fetchCore). */
function authenticate(request: ParsedRequest): OdspUser {
  if (header(request, 'x-requeststats') === undefined) {
    throw new OdspHttpError(400, 'invalidRequest', 'missing X-RequestStats');
  }
  const authorization = header(request, 'authorization');
  const token = authorization?.startsWith('Bearer ') === true ? authorization.slice('Bearer '.length) : undefined;
  const user = token === undefined ? undefined : userFromToken(token, 'storage');
  if (user === undefined) {
    throw new OdspHttpError(401, 'unauthenticated', `invalid storage authorization ${JSON.stringify(authorization)}`);
  }
  return user;
}

/** EpochTracker sends the learned epoch back; a different epoch is a 409 that carries the file's epoch. */
function checkEpoch(request: ParsedRequest, file: OdspFile): void {
  const epoch = header(request, 'x-fluid-epoch');
  if (epoch !== undefined && epoch !== file.epoch) {
    throw new OdspHttpError(409, 'fluidEpochMismatch', `epoch ${epoch} != ${file.epoch}`);
  }
}

function json(status: number, body: object, file: OdspFile | undefined): Reply {
  return { status, body, headers: file === undefined ? {} : { 'x-fluid-epoch': file.epoch } };
}

function apiRoot(request: ParsedRequest): string {
  return `${request.origin}/_api/v2.1`;
}

function itemUrl(request: ParsedRequest, drive: OdspDrive, file: OdspFile): string {
  return `${apiRoot(request)}/drives/${drive.driveId}/items/${file.itemId}`;
}

function requireQuery(request: ParsedRequest, allowed: readonly string[]): void {
  for (const key of request.url.searchParams.keys()) {
    if (!allowed.includes(key)) {
      throw new OdspHttpError(400, 'invalidRequest', `unsupported query parameter ${key}`);
    }
  }
}

export class OdspRest {
  readonly records: RestRecord[] = [];

  constructor(private readonly context: RestContext) {}

  async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    let route = `${request.method} ${request.url}`;
    let reply: Reply;
    try {
      const parsed = await parseRequest(request);
      route = `${parsed.method} ${parsed.url.pathname}`;
      reply = await this.route(parsed);
    } catch (error) {
      const status = error instanceof OdspHttpError ? error.status : 500;
      const code = error instanceof OdspHttpError ? error.code : 'generalException';
      const message = error instanceof Error ? error.message : String(error);
      reply = { status, body: { error: { code, message } } };
    }
    const errorText = reply.status >= 400 ? JSON.stringify(reply.body) : undefined;
    if (errorText !== undefined) {
      serverFailures.push(`rest ${route} -> ${reply.status} ${errorText}`);
    }
    this.records.push(errorText === undefined ? { method: request.method ?? '', route, status: reply.status } : { method: request.method ?? '', route, status: reply.status, error: errorText });
    const body = Buffer.isBuffer(reply.body) ? reply.body : Buffer.from(JSON.stringify(reply.body), 'utf8');
    response.writeHead(reply.status, {
      'content-type': reply.contentType ?? 'application/json',
      'content-length': String(body.length),
      ...reply.headers,
    });
    response.end(body);
  }

  private async route(request: ParsedRequest): Promise<Reply> {
    const prefix = `/_api/v2.1/drives/${this.context.drive.driveId}/items/`;
    const path = request.url.pathname;
    if (!path.startsWith(prefix)) {
      throw new OdspHttpError(404, 'itemNotFound', `no route ${path}`);
    }
    const rest = path.slice(prefix.length);
    const createEmpty = /^root:([^/]*)\/([^/]+):\/content$/.exec(rest);
    if (createEmpty?.[1] !== undefined && createEmpty[2] !== undefined && request.method === 'PUT') {
      return this.createEmptyFile(request, decodeURIComponent(createEmpty[1]), decodeURIComponent(createEmpty[2]));
    }
    const createFromSummary = /^root:([^/]*)\/([^/]+):\/opStream\/snapshots\/snapshot$/.exec(rest);
    if (createFromSummary?.[1] !== undefined && createFromSummary[2] !== undefined && request.method === 'POST') {
      return this.createFromSummary(request, decodeURIComponent(createFromSummary[1]), decodeURIComponent(createFromSummary[2]));
    }
    const item = /^([^/:]+)(\/.*)?$/.exec(rest);
    if (item?.[1] === undefined) {
      throw new OdspHttpError(404, 'itemNotFound', `no route ${path}`);
    }
    const file = this.context.drive.file(item[1]);
    const action = `${request.method} ${item[2] ?? ''}`;
    const user = authenticate(request);
    checkEpoch(request, file);
    if (action === 'PATCH ') {
      return this.rename(request, file);
    }
    if (action === 'POST /opStream/joinSession') {
      return this.joinSession(request, file, user);
    }
    if (action === 'GET /opStream/snapshots/trees/latest') {
      return this.treesLatest(request, file);
    }
    if (action === 'GET /opStream') {
      return this.deltas(request, file);
    }
    if (action === 'POST /opStream/snapshots/snapshot') {
      return this.uploadSummary(request, file);
    }
    if (action === 'POST /opStream/attachment/content') {
      return this.createBlob(request, file);
    }
    const blob = /^GET \/opStream\/attachments\/([^/]+)\/content$/.exec(action);
    if (blob?.[1] !== undefined) {
      return this.readBlob(request, file, decodeURIComponent(blob[1]));
    }
    throw new OdspHttpError(404, 'itemNotFound', `no route ${action}`);
  }

  /** createFile.ts createNewEmptyFluidFile: PUT `.../root:<folder>/<name>.tmp:/content`, rename on conflict. */
  private async createEmptyFile(request: ParsedRequest, folder: string, name: string): Promise<Reply> {
    authenticate(request);
    requireQuery(request, ['@name.conflictBehavior', 'select']);
    if (request.url.searchParams.get('@name.conflictBehavior') !== 'rename' || request.url.searchParams.get('select') !== 'id,name,parentReference') {
      throw new OdspHttpError(400, 'invalidRequest', 'unexpected empty-file query');
    }
    if (request.body.length !== 0) {
      throw new OdspHttpError(400, 'invalidRequest', 'empty-file create has a body');
    }
    const file = this.context.drive.create(folder, this.context.drive.availableName(folder, name));
    await this.context.createSession(file);
    return json(201, {
      '@odata.context': `${apiRoot(request)}/$metadata#items/$entity`,
      id: file.itemId,
      name: file.name,
      parentReference: { driveId: this.context.drive.driveId, path: `/drives/${this.context.drive.driveId}/root:${folder}` },
    }, file);
  }

  /** createNewUtils.ts createNewFluidContainerCore: POST `.../root:<folder>/<name>:/opStream/snapshots/snapshot`. */
  private async createFromSummary(request: ParsedRequest, folder: string, name: string): Promise<Reply> {
    authenticate(request);
    requireQuery(request, ['ump']);
    // UMP form (auth in the body) overrides to POST; the large-body form is a plain POST.
    const override = header(request, 'x-http-method-override');
    if (override !== undefined && override !== 'POST') {
      throw new OdspHttpError(400, 'invalidRequest', 'create override must be POST');
    }
    if (header(request, 'content-type') !== 'application/json') {
      throw new OdspHttpError(400, 'invalidRequest', 'create body must be application/json');
    }
    const payload = summaryPayloadSchema.parse(JSON.parse(request.body.toString('utf8')));
    if (payload.type !== 'container' || payload.sequenceNumber !== 0) {
      throw new OdspHttpError(400, 'invalidRequest', 'create-new requires a container summary at sequence 0');
    }
    if (this.context.drive.findByPath(folder, name) !== undefined) {
      throw new OdspHttpError(409, 'nameAlreadyExists', `${folder}/${name} exists`);
    }
    const file = this.context.drive.create(folder, name);
    const snapshot = file.buildSnapshot(payload, undefined);
    file.snapshots.set(snapshot.id, snapshot);
    file.latestId = snapshot.id;
    await this.context.createSession(file);
    return json(201, {
      '@odata.context': `${apiRoot(request)}/$metadata#Microsoft.FileServices.Fluid.CreateFileResponse`,
      driveId: this.context.drive.driveId,
      id: snapshot.id,
      itemId: file.itemId,
      itemUrl: itemUrl(request, this.context.drive, file),
      sequenceNumber: snapshot.sequenceNumber,
      name: file.name,
    }, file);
  }

  /** createFile.ts renameEmptyFluidFile: PATCH `items/<id>?@name.conflictBehavior=rename` `{name}`. */
  private rename(request: ParsedRequest, file: OdspFile): Reply {
    requireQuery(request, ['@name.conflictBehavior']);
    const body = renameSchema.parse(JSON.parse(request.body.toString('utf8')));
    file.name = this.context.drive.availableName(file.folder, body.name);
    return json(200, { '@odata.context': `${apiRoot(request)}/$metadata#items/$entity`, id: file.itemId, name: file.name }, file);
  }

  /** vroom.ts fetchJoinSession: discovery of the relay session and the storage endpoints. */
  private joinSession(request: ParsedRequest, file: OdspFile, user: OdspUser): Reply {
    requireQuery(request, ['ump']);
    const prefer = request.headers.get('prefer') ?? [];
    if (!prefer.includes('Return-Sensitivity-Labels')) {
      throw new OdspHttpError(400, 'invalidRequest', 'join session without Prefer: Return-Sensitivity-Labels');
    }
    const body = request.body.length === 0 ? {} : joinBodySchema.parse(JSON.parse(request.body.toString('utf8')));
    const session = this.context.session(file);
    const base = itemUrl(request, this.context.drive, file);
    return json(200, {
      id: file.documentId,
      tenantId: session.tenantId,
      snapshotStorageUrl: `${base}/opStream/snapshots`,
      deltaStorageUrl: `${base}/opStream`,
      deltaStreamSocketUrl: request.origin,
      refreshSessionDurationSeconds: 3600,
      ...(body.requestSocketToken === true ? { socketToken: `push:${user.id}` } : {}),
    }, file);
  }

  /** fetchSnapshot.ts downloadSnapshot: trees/latest, answered in the compact binary format. */
  private treesLatest(request: ParsedRequest, file: OdspFile): Reply {
    requireQuery(request, ['ump', 'mds', 'blobs', 'deltas', 'channels', 'groupId']);
    const groupId = request.url.searchParams.get('groupId');
    if (groupId !== null && groupId !== '') {
      throw new OdspHttpError(400, 'invalidRequest', `loading group ${groupId} is not supported`);
    }
    const prefer = header(request, 'prefer');
    if (prefer !== 'manualredirect') {
      throw new OdspHttpError(400, 'invalidRequest', `snapshot prefer ${prefer}`);
    }
    if (header(request, 'accept')?.includes('application/ms-fluid') !== true) {
      throw new OdspHttpError(406, 'notAcceptable', 'only application/ms-fluid snapshots are served');
    }
    return {
      status: 200,
      body: Buffer.from(file.compactSnapshot()),
      contentType: 'application/ms-fluid; v=1.0',
      headers: { 'x-fluid-epoch': file.epoch },
    };
  }

  /** odspDeltaStorageService.ts: `filter=sequenceNumber ge F and sequenceNumber le T`, wrapped ops. */
  private deltas(request: ParsedRequest, file: OdspFile): Reply {
    requireQuery(request, ['ump', 'filter']);
    const filter = /^sequenceNumber ge (\d+) and sequenceNumber le (\d+)$/.exec(request.url.searchParams.get('filter') ?? '');
    if (filter?.[1] === undefined || filter[2] === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', 'invalid ops filter');
    }
    const ops = file.opsInRange(Number(filter[1]), Number(filter[2]));
    return json(200, { value: ops.map(op => ({ op, sequenceNumber: op.sequenceNumber })) }, file);
  }

  /**
   * odspSummaryUploadManager.ts: a single-commit summary proposal. `If-Match` names the relay session
   * and the parent (`containerid`), which must be the latest committed snapshot (else 412). The
   * proposal is committed when its summarize op is acked; a file's first summary (empty-file
   * creation flow, no parent) is committed immediately.
   */
  private uploadSummary(request: ParsedRequest, file: OdspFile): Reply {
    requireQuery(request, []);
    if (header(request, 'content-type') !== 'application/json') {
      throw new OdspHttpError(400, 'invalidRequest', 'summary body must be application/json');
    }
    const payload = summaryPayloadSchema.parse(JSON.parse(request.body.toString('utf8')));
    if (payload.type !== 'container') {
      throw new OdspHttpError(400, 'invalidRequest', 'channel summaries need service protocol generation, not implemented');
    }
    const session = this.context.session(file);
    const ifMatch = header(request, 'if-match');
    const match = ifMatch === undefined ? undefined : /^fluid:sessionid=([^;]+)(?:;containerid=(.+))?$/.exec(ifMatch);
    if (ifMatch !== undefined && match?.[1] !== `${session.tenantId}/${file.documentId}`) {
      throw new OdspHttpError(412, 'preconditionFailed', `If-Match ${ifMatch} does not name this session`);
    }
    const parentId = match?.[2];
    if (parentId === undefined) {
      if (file.latestId !== undefined || payload.sequenceNumber !== 0) {
        throw new OdspHttpError(412, 'preconditionFailed', 'summary without a parent on a file that has one');
      }
      const snapshot = file.buildSnapshot(payload, undefined);
      file.snapshots.set(snapshot.id, snapshot);
      file.latestId = snapshot.id;
      return json(200, { id: snapshot.id }, file);
    }
    const parent = file.latest;
    if (parent === undefined || parent.id !== parentId) {
      throw new OdspHttpError(412, 'preconditionFailed', `parent ${parentId} is not the latest ${file.latestId}`);
    }
    // Single-commit summaries flush first: every op up to the summary must already be persisted.
    if (payload.sequenceNumber < parent.sequenceNumber || payload.sequenceNumber > file.lastPersistedSequenceNumber) {
      throw new OdspHttpError(400, 'invalidRequest', `summary seq ${payload.sequenceNumber} outside [${parent.sequenceNumber}, ${file.lastPersistedSequenceNumber}]`);
    }
    const snapshot = file.buildSnapshot(payload, parent);
    file.proposals.set(snapshot.id, { snapshot, parentId });
    return json(200, { id: snapshot.id }, file);
  }

  /** odspDocumentStorageManager.ts createBlob: raw bytes, octet-stream. */
  private createBlob(request: ParsedRequest, file: OdspFile): Reply {
    requireQuery(request, []);
    if (header(request, 'content-type') !== 'application/octet-stream') {
      throw new OdspHttpError(400, 'invalidRequest', 'attachment body must be application/octet-stream');
    }
    const id = file.storeAttachment(new Uint8Array(request.body));
    return json(200, { id }, file);
  }

  /** fetchBlobFromStorage: the driver logs NonCacheableBlob unless cache-control says private/public. */
  private readBlob(request: ParsedRequest, file: OdspFile, blobId: string): Reply {
    requireQuery(request, []);
    const bytes = file.readBlob(blobId);
    if (bytes === undefined) {
      throw new OdspHttpError(404, 'itemNotFound', `blob ${blobId} not found`);
    }
    return {
      status: 200,
      body: Buffer.from(bytes),
      contentType: 'application/octet-stream',
      headers: { 'x-fluid-epoch': file.epoch, 'cache-control': 'private, max-age=31536000' },
    };
  }
}
