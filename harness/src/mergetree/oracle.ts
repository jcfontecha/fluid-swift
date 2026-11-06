import { Client } from '../../node_modules/@fluidframework/merge-tree/lib/client.js';
import { Marker } from '../../node_modules/@fluidframework/merge-tree/lib/mergeTreeNodes.js';
import { createChildLogger } from '@fluidframework/telemetry-utils/internal';
import { TestSerializer } from '../../node_modules/@fluidframework/merge-tree/lib/test/testSerializer.js';
class Serializer extends TestSerializer {
    override stringify(value: unknown): string {
        return JSON.stringify(value);
    }
}
const serializer = new Serializer();
import { TextSegment } from '../../node_modules/@fluidframework/merge-tree/lib/textSegment.js';
import { PriorPerspective } from '../../node_modules/@fluidframework/merge-tree/lib/perspective.js';
import { SnapshotV1 } from '../../node_modules/@fluidframework/merge-tree/lib/snapshotV1.js';
import { SnapshotLegacy } from '../../node_modules/@fluidframework/merge-tree/lib/snapshotlegacy.js';
import { MockHandle } from '@fluidframework/test-runtime-utils/internal';
import type { LocalReferencePosition } from '../../node_modules/@fluidframework/merge-tree/lib/localReference.js';
import type { ISequencedDocumentMessage } from '@fluidframework/driver-definitions/internal';
import { editSchema, messageSchema, requestSchema } from './protocol.js';
import { createInterface } from 'node:readline';
class Oracle extends Client {
    constructor(obliterate = false) {
        super(spec => {
            const s = TextSegment.fromJSONObject(spec) ?? Marker.fromJSONObject(spec);
            if (!s)
                throw Error('invalid segment');
            return s;
        }, createChildLogger(), { mergeTreeEnableObliterate: obliterate, newMergeTreeSnapshotFormat: true });
    }
    get mergeTree() {
        return this['_mergeTree'];
    }
    readonly references = new Map<string, LocalReferencePosition>();
    state() {
        const text: number[] = [];
        const segments: unknown[] = [];
        this.walkSegments(s => {
            segments.push(s.toJSONObject());
            if (TextSegment.is(s))
                for (let i = 0; i < s.text.length; i++)
                    text.push(s.text.charCodeAt(i));
            return true;
        });
        const w = this.getCollabWindow();
        const lengths: number[] = [];
        for (let seq = w.minSeq; seq <= w.currentSeq; seq++)
            for (const id of ['A', 'B', 'C'])
                lengths.push(this.mergeTree.getLength(new PriorPerspective(seq, this.getShortClientId(id))));
        return { text, length: this.getLength(), segments, references: Object.fromEntries([...this.references].map(([id, r]) => [id, this.localReferencePositionToPosition(r)])), lengths };
    }
}
const clients = new Map<string, Oracle>();
console.log = (...values: unknown[]) => process.stderr.write(values.map(String).join(' ') + '\n');
for await (const line of createInterface({ input: process.stdin })) {
    let id = 0;
    try {
        const req = requestSchema.parse(JSON.parse(line));
        id = req.id;
        const p = req.params;
        let result: unknown = null;
        if (req.method === 'reset')
            clients.clear();
        else if (req.method === 'create') {
            if (!p.client)
                throw Error('client required');
            const c = new Oracle(p.obliterate);
            c.startOrUpdateCollaboration(p.client);
            clients.set(p.client, c);
        }
        else {
            const c = clients.get(p.client ?? '');
            if (!c)
                throw Error('unknown client');
            switch (req.method) {
                case 'edit': {
                    const e = editSchema.parse(p.edit);
                    switch (e.kind) {
                        case 'insert':
                            result = c.insertSegmentLocal(e.pos, new TextSegment(e.text));
                            break;
                        case 'marker':
                            result = c.insertSegmentLocal(e.pos, Marker.make(0));
                            break;
                        case 'remove':
                            result = c.removeRangeLocal(e.start, e.end);
                            break;
                        case 'obliterate':
                            result = c.obliterateRangeLocal(e.start, e.end);
                            break;
                        case 'annotate':
                            result = c.annotateRangeLocal(e.start, e.end, e.props ?? {});
                            break;
                        case 'reference': {
                            const found = c.getContainingSegment(e.pos);
                            if (!found)
                                throw Error('reference out of bounds');
                            const { segment, offset } = found;
                            c.references.set(e.id, c.createLocalReferencePosition(segment, offset, e.refType, undefined));
                            break;
                        }
                    }
                    break;
                }
                case 'process': {
                    const m = messageSchema.parse(p.message);
                    c.applyMsg({ ...m, contents: m.contents, term: 1, timestamp: 0 } as ISequencedDocumentMessage);
                    break;
                }
                case 'state':
                    result = c.state();
                    break;
                case 'minSeq':
                    if (p.seq === undefined)
                        throw Error('seq required');
                    c.updateMinSeq(p.seq);
                    break;
                case 'snapshot': {
                    const snap = p.version === 'legacy' ? new SnapshotLegacy(c.mergeTree, c.logger) : new SnapshotV1(c.mergeTree, c.logger, id => c.getLongClientId(id));
                    snap.extractSync();
                    result = snap instanceof SnapshotLegacy ? snap.emit([], serializer, new MockHandle(null)).summary : snap.emit(serializer, new MockHandle(null)).summary;
                    break;
                }
            }
        }
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result: result ?? null }) + '\n');
    }
    catch (error) {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message: String(error) } }) + '\n');
    }
}
