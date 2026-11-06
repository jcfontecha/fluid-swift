// SharePoint Embedded storage for the local ODSP service: drive items, committed snapshots,
// summary proposals, attachment blobs and the persisted op stream ("opStream").
//
// Shapes come from the 3.11.0 driver: upload payloads are
// odsp-driver/src/contracts.ts `IOdspSummaryPayload` (written by odspSummaryUploadManager.ts and
// createFile/createNewUtils.ts), snapshots are served as `ISnapshot` encoded with the driver's own
// compactSnapshotWriter.ts. Handle entries are `<parentHandle>/.app<handlePath>`
// (odspSummaryUploadManager.ts convertSummaryToSnapshotTree).
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { ISequencedDocumentMessage, ISnapshot, ISnapshotTree } from '@fluidframework/driver-definitions/internal';
import { convertToCompactSnapshot } from '../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotWriter.js';

/** An HTTP-visible failure: the REST layer turns it into a status code and an ODSP error body. */
export class OdspHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

type UploadBlob = { type: 'blob'; content: string; encoding: 'utf-8' | 'base64' };
type UploadTree = { type: 'tree'; entries: UploadEntry[] };
type UploadEntry =
  | { value: UploadTree; path: string; type: 'tree'; unreferenced?: true; groupId?: string }
  | { value: UploadBlob; path: string; type: 'blob' }
  | { path: string; type: 'tree' | 'blob'; id: string };

const blobSchema: z.ZodType<UploadBlob> = z.strictObject({
  type: z.literal('blob'),
  content: z.string(),
  encoding: z.enum(['utf-8', 'base64']),
});
const treeSchema: z.ZodType<UploadTree> = z.lazy(() => z.strictObject({
  type: z.literal('tree'),
  entries: z.array(entrySchema),
}));
const entrySchema: z.ZodType<UploadEntry> = z.lazy(() => z.union([
  z.strictObject({
    value: treeSchema,
    path: z.string(),
    type: z.literal('tree'),
    unreferenced: z.literal(true).optional(),
    groupId: z.string().optional(),
  }),
  z.strictObject({ value: blobSchema, path: z.string(), type: z.literal('blob') }),
  z.strictObject({ path: z.string(), type: z.enum(['tree', 'blob']), id: z.string() }),
]));
/** contracts.ts IOdspSummaryPayload; property order on the wire is entries, message, sequenceNumber, type. */
export const summaryPayloadSchema = z.strictObject({
  entries: z.array(entrySchema),
  message: z.string(),
  sequenceNumber: z.number().int().nonnegative(),
  type: z.enum(['container', 'channel']),
});
export type SummaryPayload = z.infer<typeof summaryPayloadSchema>;

const attributesSchema = z.object({
  minimumSequenceNumber: z.number().int(),
  sequenceNumber: z.number().int(),
});

export interface StoredSnapshot {
  readonly id: string;
  /** The summary's reference sequence number (payload `sequenceNumber`). */
  readonly sequenceNumber: number;
  /** Root with `.app` and `.protocol` children; leaf values are blob or attachment ids. */
  readonly tree: ISnapshotTree;
}

interface Proposal {
  readonly snapshot: StoredSnapshot;
  readonly parentId: string;
}

/** Drive item ids look like SharePoint's: "01" followed by 32 base32 characters. */
function newItemId(): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const bytes = randomBytes(32);
  let id = '01';
  for (const byte of bytes) {
    id += alphabet[byte % 32];
  }
  return id;
}

function contentId(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function emptyTree(): ISnapshotTree {
  return { blobs: {}, trees: {} };
}

/** A Fluid file in the drive. The orderer document id is `documentId`, distinct from `itemId`. */
export class OdspFile {
  readonly itemId = newItemId();
  readonly epoch = randomUUID();
  /** Relay session identity returned by join session (`id`); also the orderer document id. */
  readonly documentId = randomUUID();
  readonly blobs = new Map<string, Uint8Array>();
  readonly attachments = new Map<string, Uint8Array>();
  readonly snapshots = new Map<string, StoredSnapshot>();
  readonly proposals = new Map<string, Proposal>();
  /** Persisted sequenced ops; index i holds sequence number i + 1. */
  readonly ops: ISequencedDocumentMessage[] = [];
  latestId: string | undefined;
  /** How many uploaded entries reused a parent subtree or blob by handle. */
  handleReferences = 0;

  constructor(
    public name: string,
    readonly folder: string,
  ) {}

  get latest(): StoredSnapshot | undefined {
    if (this.latestId === undefined) {
      return undefined;
    }
    return this.snapshots.get(this.latestId);
  }

  get lastPersistedSequenceNumber(): number {
    return this.ops.length;
  }

  /** Called in sequence order by the op-store lambda. Sequence numbers must be contiguous from 1. */
  persistOp(op: ISequencedDocumentMessage): void {
    if (op.sequenceNumber !== this.ops.length + 1) {
      throw new Error(`op stream gap: got ${op.sequenceNumber} after ${this.ops.length}`);
    }
    this.ops.push(op);
  }

  /** Inclusive range, as the opStream filter `sequenceNumber ge from and sequenceNumber le to`. */
  opsInRange(from: number, to: number): ISequencedDocumentMessage[] {
    const start = Math.max(from, 1) - 1;
    const end = Math.min(to, this.ops.length);
    return this.ops.slice(start, end);
  }

  storeBlob(bytes: Uint8Array): string {
    const id = contentId(bytes);
    this.blobs.set(id, bytes);
    return id;
  }

  storeAttachment(bytes: Uint8Array): string {
    const id = randomUUID().replaceAll('-', '');
    this.attachments.set(id, bytes);
    return id;
  }

  readBlob(id: string): Uint8Array | undefined {
    return this.blobs.get(id) ?? this.attachments.get(id);
  }

  /**
   * Converts an uploaded payload into a stored snapshot. `parent` is the snapshot that handle
   * entries may reference; it is undefined for the first summary of a file.
   */
  buildSnapshot(payload: SummaryPayload, parent: StoredSnapshot | undefined): StoredSnapshot {
    const tree = this.buildTree(payload.entries, parent);
    const protocol = tree.trees['.protocol'];
    if (protocol === undefined || tree.trees['.app'] === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', 'container summary requires .protocol and .app');
    }
    const attributesId = protocol.blobs['attributes'];
    if (attributesId === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', '.protocol/attributes is missing');
    }
    const attributesBytes = this.blobs.get(attributesId);
    if (attributesBytes === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', '.protocol/attributes must be a value blob');
    }
    const attributes = attributesSchema.parse(JSON.parse(Buffer.from(attributesBytes).toString('utf8')));
    // The protocol attributes and the payload both carry the summary sequence number.
    if (attributes.sequenceNumber !== payload.sequenceNumber) {
      throw new OdspHttpError(400, 'invalidRequest', `attributes seq ${attributes.sequenceNumber} != payload seq ${payload.sequenceNumber}`);
    }
    const id = randomUUID();
    tree.id = id;
    return { id, sequenceNumber: payload.sequenceNumber, tree };
  }

  private buildTree(entries: UploadEntry[], parent: StoredSnapshot | undefined): ISnapshotTree {
    const tree = emptyTree();
    for (const entry of entries) {
      this.addEntry(tree, entry, parent);
    }
    return tree;
  }

  private addEntry(tree: ISnapshotTree, entry: UploadEntry, parent: StoredSnapshot | undefined): void {
    // Keys never contain '/' (assert 0x9cd); '__proto__' cannot be a plain-object key in ISnapshotTree.
    if (entry.path.includes('/') || entry.path === '__proto__') {
      throw new OdspHttpError(400, 'invalidRequest', `invalid entry path ${JSON.stringify(entry.path)}`);
    }
    if (entry.path in tree.trees || entry.path in tree.blobs) {
      throw new OdspHttpError(400, 'invalidRequest', `duplicate entry path ${entry.path}`);
    }
    if ('id' in entry) {
      this.addReference(tree, entry.path, entry.type, entry.id, parent);
      return;
    }
    if (entry.type === 'blob') {
      const bytes = entry.value.encoding === 'base64'
        ? Buffer.from(entry.value.content, 'base64')
        : Buffer.from(entry.value.content, 'utf8');
      tree.blobs[entry.path] = this.storeBlob(bytes);
      return;
    }
    // Loading groups change which content trees/latest returns; this service does not implement them.
    if (entry.groupId !== undefined) {
      throw new OdspHttpError(400, 'invalidRequest', `groupId ${entry.groupId} is not supported`);
    }
    const child = this.buildTree(entry.value.entries, parent);
    if (entry.unreferenced === true) {
      child.unreferenced = true;
    }
    tree.trees[entry.path] = child;
  }

  private addReference(
    tree: ISnapshotTree,
    path: string,
    type: 'tree' | 'blob',
    id: string,
    parent: StoredSnapshot | undefined,
  ): void {
    // Attachment entries carry the attachment id verbatim (SummaryType.Attachment).
    if (!id.includes('/')) {
      if (type !== 'blob' || !this.attachments.has(id)) {
        throw new OdspHttpError(400, 'invalidRequest', `unknown attachment ${id}`);
      }
      tree.blobs[path] = id;
      return;
    }
    if (parent === undefined || !id.startsWith(`${parent.id}/`)) {
      throw new OdspHttpError(400, 'invalidRequest', `handle ${id} does not reference the parent summary`);
    }
    this.handleReferences++;
    const segments = id.slice(parent.id.length + 1).split('/');
    const name = segments.pop();
    let node: ISnapshotTree | undefined = parent.tree;
    for (const segment of segments) {
      node = node?.trees[segment];
    }
    if (node === undefined || name === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', `handle ${id} not found in parent`);
    }
    if (type === 'tree') {
      const subtree = node.trees[name];
      if (subtree === undefined) {
        throw new OdspHttpError(400, 'invalidRequest', `tree handle ${id} not found in parent`);
      }
      tree.trees[path] = structuredClone(subtree);
      return;
    }
    const blobId = node.blobs[name];
    if (blobId === undefined) {
      throw new OdspHttpError(400, 'invalidRequest', `blob handle ${id} not found in parent`);
    }
    tree.blobs[path] = blobId;
  }

  /** trees/latest: the latest committed snapshot plus every persisted op after it. */
  compactSnapshot(): Uint8Array {
    const latest = this.latest;
    if (latest === undefined) {
      throw new OdspHttpError(404, 'itemNotFound', 'file has no snapshot');
    }
    const blobContents = new Map<string, ArrayBuffer>();
    this.collectBlobs(latest.tree, blobContents);
    const ops = this.opsInRange(latest.sequenceNumber + 1, this.ops.length);
    const snapshot: ISnapshot = {
      snapshotTree: latest.tree,
      blobContents,
      ops,
      sequenceNumber: latest.sequenceNumber,
      latestSequenceNumber: ops.length > 0 ? this.ops.length : latest.sequenceNumber,
      snapshotFormatV: 1,
    };
    return convertToCompactSnapshot(snapshot);
  }

  /** Snapshot blobs travel inline; attachment blobs are fetched through the attachments endpoint. */
  private collectBlobs(tree: ISnapshotTree, blobContents: Map<string, ArrayBuffer>): void {
    for (const id of Object.values(tree.blobs)) {
      const bytes = this.blobs.get(id);
      if (bytes !== undefined) {
        blobContents.set(id, new Uint8Array(bytes).buffer);
      }
    }
    for (const child of Object.values(tree.trees)) {
      this.collectBlobs(child, blobContents);
    }
  }
}

/** A file's full storage state as JSON, written next to a failing seed's trace for replay.ts. */
export interface FileDump {
  readonly latestId: string | undefined;
  readonly snapshots: StoredSnapshot[];
  readonly blobs: Record<string, string>;
  readonly attachments: Record<string, string>;
  readonly ops: ISequencedDocumentMessage[];
}

export function dumpFile(file: OdspFile): FileDump {
  const base64 = (map: Map<string, Uint8Array>) => Object.fromEntries([...map].map(([id, bytes]) => [id, Buffer.from(bytes).toString('base64')]));
  return {
    latestId: file.latestId,
    snapshots: [...file.snapshots.values()],
    blobs: base64(file.blobs),
    attachments: base64(file.attachments),
    ops: file.ops,
  };
}

/** One SharePoint Embedded drive: items addressed by id and by `folder/name`. */
export class OdspDrive {
  readonly files = new Map<string, OdspFile>();

  constructor(readonly driveId: string) {}

  file(itemId: string): OdspFile {
    const file = this.files.get(itemId);
    if (file === undefined) {
      throw new OdspHttpError(404, 'itemNotFound', `item ${itemId} not found`);
    }
    return file;
  }

  findByPath(folder: string, name: string): OdspFile | undefined {
    for (const file of this.files.values()) {
      if (file.folder === folder && file.name === name) {
        return file;
      }
    }
    return undefined;
  }

  /** `@name.conflictBehavior=rename`: "a.tmp" becomes "a 1.tmp", "a 2.tmp", ... */
  availableName(folder: string, name: string): string {
    if (this.findByPath(folder, name) === undefined) {
      return name;
    }
    const dot = name.lastIndexOf('.');
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const extension = dot > 0 ? name.slice(dot) : '';
    for (let index = 1; ; index++) {
      const candidate = `${stem} ${index}${extension}`;
      if (this.findByPath(folder, candidate) === undefined) {
        return candidate;
      }
    }
  }

  /** Recreates a dumped file under a new item id (replay.ts). */
  restore(dump: FileDump): OdspFile {
    const file = this.create('', `restored-${this.files.size}`);
    for (const snapshot of dump.snapshots) {
      file.snapshots.set(snapshot.id, snapshot);
    }
    for (const [id, data] of Object.entries(dump.blobs)) {
      file.blobs.set(id, Buffer.from(data, 'base64'));
    }
    for (const [id, data] of Object.entries(dump.attachments)) {
      file.attachments.set(id, Buffer.from(data, 'base64'));
    }
    for (const op of dump.ops) {
      file.persistOp(op);
    }
    file.latestId = dump.latestId;
    return file;
  }

  create(folder: string, name: string): OdspFile {
    const file = new OdspFile(name, folder);
    this.files.set(file.itemId, file);
    return file;
  }
}
