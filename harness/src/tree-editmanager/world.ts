import assert from 'node:assert/strict';
import { createIdCompressor } from '@fluidframework/id-compressor/internal';
import type { SessionId } from '@fluidframework/id-compressor';
import { EditManager } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManager.js';
import type { SharedTreeBranch } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/branch.js';
import { makeV1toV4andV6CodecWithVersion } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerCodecsV1toV4.js';
import { makeSharedBranchesCodecWithVersion } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerCodecsVSharedBranches.js';
import { EditManagerFormatVersion } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerFormatCommons.js';
import type { EditManagerEncodingContext } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerCodecsCommons.js';
import { ModularChangeFamily, type ModularEditBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeFamily.js';
import { makeModularChangeCodecFamily } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeCodecs.js';
import type { ModularChangeset, FieldChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeTypes.js';
import { fieldKinds, fieldKindConfigurations } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/default-schema/defaultFieldKinds.js';
import { fieldBatchCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/index.js';
import { sequenceFieldEditor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldEditor.js';
import { areInputCellsEmpty, areOutputCellsEmpty } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/utils.js';
import type { MarkList } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/types.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { CommitKind, tagChange } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { ChangeAtomId, CustomMetadataTree, FieldKindIdentifier, FieldUpPath, GraphCommit, RevisionTag } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { FluidClientVersion, FormatValidatorNoOp } from '../../node_modules/@fluidframework/tree/lib/codec/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { SeqNumber } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerFormatCommons.js';

export type FieldKey = 'a' | 'b';
export interface EditSpec {
    kind: 'insert' | 'remove' | 'move' | 'crossMove' | 'nested';
    field: FieldKey;
    index: number;
    count: number;
    destination: number;
    metadata: number;
}
export type SummaryFormat = 3 | 4 | 6 | 7 | 'shared';
export const summaryFormats: readonly SummaryFormat[] = [3, 4, 6, 7, 'shared'];
export type Action =
    | { type: 'edit'; peer: number; edits: EditSpec[] }
    | { type: 'noop'; peer: number }
    | { type: 'sequence'; peer: number }
    | { type: 'deliver'; peer: number; split: number }
    | { type: 'retention'; peer: number; value: boolean | number }
    | { type: 'fork'; peer: number }
    | { type: 'rebaseFork'; peer: number; fork: number }
    | { type: 'disposeFork'; peer: number; fork: number }
    | { type: 'join'; from: number; format: SummaryFormat }
    | { type: 'snapshot'; peer: number };
export interface Scenario {
    seed: number;
    peers: number;
    actions: Action[];
}
export type Lengths = Record<FieldKey, number>;

type Manager = EditManager<ModularEditBuilder, ModularChangeset>;
type Branch = SharedTreeBranch<ModularEditBuilder, ModularChangeset, never>;
interface WireCommit {
    revision: RevisionTag;
    bytes: string;
    metadata: number;
}
type Message = { kind: 'op'; refSeq: number; commits: WireCommit[] } | { kind: 'noop'; refSeq: number };
interface Sequenced {
    seq: number;
    msn: number;
    client: number;
    message: Message;
}
class Peer {
    readonly forks: (Branch | undefined)[] = [];
    readonly outbox: Message[] = [];
    processed = 0;
    lastSeq = 0;
    constructor(readonly session: SessionId, readonly manager: Manager) {}
}

// Session ids are UUID-shaped strings; only the EditManager compares them.
export function sessionId(index: number): SessionId {
    return `00000000-0000-4000-8000-${(index + 1).toString().padStart(12, '0')}` as SessionId;
}

// The custom metadata variants cover flat metadata, nested child metadata with an
// array-index key, and a tree without metadata (encoded as {} and decoded as undefined).
export function metadataTree(variant: number): CustomMetadataTree | undefined {
    switch (variant) {
        case 0:
            return undefined;
        case 1:
            return { metadata: { label: 'one' }, children: [] };
        case 2:
            return { metadata: undefined, children: [{ metadata: { label: 'two', 1: true }, children: [] }] };
        case 3:
            return { metadata: undefined, children: [] };
    }
    assert.fail(`unknown metadata variant ${variant}`);
}

/**
 * The TS side of T3: real 3.11.0 EditManagers, one per peer, fed by a lockstep sequencer.
 * All EditManagers share one ID compressor; every minted revision is finalized so op-space
 * revisions decode under any originator session.
 */
export class World {
    readonly compressor = createIdCompressor('00000001-0000-4000-8000-000000000000' as SessionId, 2);
    readonly options = { jsonValidator: FormatValidatorNoOp, minVersionForCollab: FluidClientVersion.v2_0 };
    readonly revisionTagCodec = new RevisionTagCodec(this.compressor);
    readonly codecs = makeModularChangeCodecFamily(fieldKindConfigurations, this.revisionTagCodec, fieldBatchCodecBuilder.build(this.options), this.options);
    readonly family = new ModularChangeFamily(fieldKinds, this.codecs, this.options);
    // shared-tree/sharedTree.ts: v3 -> modular 3, v4 and vSharedBranches -> 4, v6/v7 -> 5.
    readonly summaryCodecs = new Map<SummaryFormat, ReturnType<typeof makeV1toV4andV6CodecWithVersion<ModularChangeset>>>([
        [3, makeV1toV4andV6CodecWithVersion(this.codecs.resolve(3), this.revisionTagCodec, EditManagerFormatVersion.v3)],
        [4, makeV1toV4andV6CodecWithVersion(this.codecs.resolve(4), this.revisionTagCodec, EditManagerFormatVersion.v4)],
        [6, makeV1toV4andV6CodecWithVersion(this.codecs.resolve(5), this.revisionTagCodec, EditManagerFormatVersion.v6)],
        [7, makeV1toV4andV6CodecWithVersion(this.codecs.resolve(5), this.revisionTagCodec, EditManagerFormatVersion.v7)],
        ['shared', makeSharedBranchesCodecWithVersion(this.codecs.resolve(4), this.revisionTagCodec, EditManagerFormatVersion.vSharedBranches)],
    ]);
    readonly encodingContext: EditManagerEncodingContext<ModularChangeset> = {
        idCompressor: this.compressor,
        hasSchemaChange: (change) => this.family.hasSchemaChange(change),
        isSummary: true,
    };
    readonly peers: Peer[] = [];
    readonly sequenced: Sequenced[] = [];
    readonly clientRefSeq: number[] = [];
    readonly lengthBySeq = new Map<number, Lengths>([[0, { a: 0, b: 0 }]]);
    readonly rows: string[][] = [];
    seq = 0;
    msn = 0;

    constructor(peerCount: number) {
        for (let i = 0; i < peerCount; i++) {
            this.addPeer();
        }
    }

    mint(): RevisionTag {
        const revision = this.compressor.generateCompressedId() as RevisionTag;
        this.compressor.finalizeCreationRange(this.compressor.takeNextCreationRange());
        return revision;
    }

    addPeer(): Peer {
        const index = this.peers.length;
        const manager: Manager = new EditManager(this.family, sessionId(index), () => this.mint());
        const peer = new Peer(sessionId(index), manager);
        this.peers.push(peer);
        this.clientRefSeq.push(0);
        return peer;
    }

    peer(index: number): Peer {
        return this.peers[index] ?? assert.fail(`missing peer ${index}`);
    }

    encodeRevision(revision: RevisionTag): string {
        return JSON.stringify(this.revisionTagCodec.encode(revision));
    }

    changeBytes(change: ModularChangeset, revision: RevisionTag): string {
        const codec = this.codecs.resolve(5);
        const context = { originatorId: this.compressor.localSessionId, revision, idCompressor: this.compressor, isSummary: false };
        return JSON.stringify(codec.encode(change, context));
    }

    decodeChange(bytes: string, revision: RevisionTag): ModularChangeset {
        const codec = this.codecs.resolve(5);
        const context = { originatorId: this.compressor.localSessionId, revision, idCompressor: this.compressor, isSummary: false };
        return codec.decode(JSON.parse(bytes), context);
    }

    build(spec: EditSpec, revision: RevisionTag): ModularChangeset {
        const atom: ChangeAtomId = { localId: brand(0), revision };
        const attach: ChangeAtomId = { localId: brand(8), revision };
        const field: FieldUpPath = { parent: undefined, field: brand(spec.field) };
        const other: FieldUpPath = { parent: undefined, field: brand(spec.field === 'a' ? 'b' : 'a') };
        const builder = this.family.buildEditor(() => revision, () => {});
        const description = (path: FieldUpPath, change: MarkList) => ({
            type: 'field' as const,
            field: path,
            fieldKind: brand<FieldKindIdentifier>('Sequence'),
            change: brand<FieldChangeset>(change),
            revision,
        });
        builder.generateId(64);
        const seq = sequenceFieldEditor;
        switch (spec.kind) {
            case 'insert':
                return builder.buildChanges([description(field, seq.insert(spec.index, spec.count, atom, revision))]);
            case 'remove':
                return builder.buildChanges([description(field, seq.remove(spec.index, spec.count, atom.localId, revision))]);
            case 'move':
                return builder.buildChanges([description(field, seq.move(spec.index, spec.count, spec.destination, atom.localId, attach, revision))]);
            case 'crossMove':
                return builder.buildChanges([
                    description(field, seq.moveOut(spec.index, spec.count, atom.localId, revision)),
                    description(other, seq.moveIn(spec.destination, spec.count, atom.localId, attach, revision)),
                ]);
            case 'nested': {
                const nested: FieldUpPath = { parent: { parent: undefined, parentField: field.field, parentIndex: spec.index }, field: brand('children') };
                return builder.buildChanges([description(nested, seq.insert(0, spec.count, atom, revision))]);
            }
        }
    }

    /** Net effect of a change on the number of live nodes in one root field (generator only). */
    static delta(change: ModularChangeset, field: FieldKey): number {
        const fieldChange = change.fieldChanges.get(brand(field));
        if (fieldChange === undefined) {
            return 0;
        }
        // A nested edit wraps its root field in a generic change, which only carries child changes.
        if (fieldChange.fieldKind === 'ModularEditBuilder.Generic') {
            return 0;
        }
        assert.equal(fieldChange.fieldKind, 'Sequence');
        // A Sequence field's changeset is its mark list.
        const marks: unknown = fieldChange.change;
        assert(Array.isArray(marks));
        let delta = 0;
        for (const mark of marks) {
            const output = areOutputCellsEmpty(mark) ? 0 : mark.count;
            const input = areInputCellsEmpty(mark) ? 0 : mark.count;
            delta += output - input;
        }
        return delta;
    }

    /** The peer's local view of both root fields: trunk at its last processed seq plus its local commits. */
    viewLengths(index: number): Lengths {
        const peer = this.peer(index);
        const base = this.lengthBySeq.get(peer.lastSeq) ?? assert.fail(`no trunk length for seq ${peer.lastSeq}`);
        const lengths = { ...base };
        for (const commit of peer.manager.getLocalCommits('main')) {
            lengths.a += World.delta(commit.change, 'a');
            lengths.b += World.delta(commit.change, 'b');
        }
        return lengths;
    }

    summarizable(index: number): boolean {
        const manager = this.peer(index).manager;
        return manager.getLocalBranch('main').getHead() === manager.getTrunkHead('main');
    }

    execute(action: Action): void {
        switch (action.type) {
            case 'edit':
                this.edit(action.peer, action.edits);
                return;
            case 'noop': {
                const peer = this.peer(action.peer);
                peer.outbox.push({ kind: 'noop', refSeq: peer.lastSeq });
                return;
            }
            case 'sequence':
                this.sequence(action.peer);
                return;
            case 'deliver':
                this.deliver(action.peer, action.split);
                this.snapshot(action.peer);
                return;
            case 'retention':
                this.peer(action.peer).manager.setHistoryRetention(action.value);
                this.snapshot(action.peer);
                return;
            case 'fork': {
                const peer = this.peer(action.peer);
                peer.forks.push(peer.manager.getLocalBranch('main').fork());
                this.snapshot(action.peer);
                return;
            }
            case 'rebaseFork': {
                const peer = this.peer(action.peer);
                const fork = peer.forks[action.fork] ?? assert.fail('missing fork');
                fork.rebaseOnto(peer.manager.getLocalBranch('main'));
                this.snapshot(action.peer);
                return;
            }
            case 'disposeFork': {
                const peer = this.peer(action.peer);
                const fork = peer.forks[action.fork] ?? assert.fail('missing fork');
                fork.dispose();
                peer.forks[action.fork] = undefined;
                this.snapshot(action.peer);
                return;
            }
            case 'join':
                this.join(action.from, action.format);
                return;
            case 'snapshot':
                this.snapshot(action.peer);
                return;
        }
    }

    private edit(index: number, specs: EditSpec[]): void {
        const peer = this.peer(index);
        const branch = peer.manager.getLocalBranch('main');
        const commits: WireCommit[] = [];
        for (const spec of specs) {
            const revision = this.mint();
            const change = this.build(spec, revision);
            branch.apply(tagChange(change, revision), CommitKind.Default, metadataTree(spec.metadata));
            commits.push({ revision, bytes: this.changeBytes(change, revision), metadata: spec.metadata });
        }
        peer.outbox.push({ kind: 'op', refSeq: peer.lastSeq, commits });
        this.rows.push(['wire', String(index), String(peer.lastSeq), ...commits.flatMap(c => [this.encodeRevision(c.revision), c.bytes])]);
        this.snapshot(index);
    }

    private sequence(index: number): void {
        const message = this.peer(index).outbox.shift() ?? assert.fail('empty outbox');
        this.seq += 1;
        this.clientRefSeq[index] = message.refSeq;
        // The service's minimum sequence number never regresses.
        this.msn = Math.max(this.msn, Math.min(...this.clientRefSeq));
        this.sequenced.push({ seq: this.seq, msn: this.msn, client: index, message });
        this.rows.push(['seq', String(this.seq), String(this.msn), String(index), message.kind, String(message.refSeq)]);
    }

    private deliver(index: number, split: number): void {
        const peer = this.peer(index);
        const sequenced = this.sequenced[peer.processed] ?? assert.fail('nothing to deliver');
        const manager = peer.manager;
        const seq = brand<SeqNumber>(sequenced.seq);
        const message = sequenced.message;
        if (message.kind === 'op') {
            const commits: GraphCommit<ModularChangeset>[] = message.commits.map(c => ({
                revision: c.revision,
                change: this.decodeChange(c.bytes, c.revision),
                customMetadata: metadataTree(c.metadata),
            }));
            const session = this.peer(sequenced.client).session;
            const refSeq = brand<SeqNumber>(message.refSeq);
            if (split > 0) {
                manager.addSequencedChanges(commits.slice(0, split), session, seq, refSeq, 'main');
                manager.addSequencedChanges(commits.slice(split), session, seq, refSeq, 'main');
            } else {
                manager.addSequencedChanges(commits, session, seq, refSeq, 'main');
            }
        }
        manager.advanceMinimumSequenceNumber(brand<SeqNumber>(sequenced.msn));
        peer.processed += 1;
        peer.lastSeq = sequenced.seq;
        if (!this.lengthBySeq.has(sequenced.seq)) {
            // Sequence numbers are consecutive, so the previous entry is always recorded first.
            const previous = this.lengthBySeq.get(sequenced.seq - 1) ?? assert.fail('missing previous trunk length');
            const lengths = { ...previous };
            if (message.kind === 'op') {
                const trunk = manager.getTrunkCommits('main');
                for (const commit of trunk.slice(trunk.length - message.commits.length)) {
                    lengths.a += World.delta(commit.change, 'a');
                    lengths.b += World.delta(commit.change, 'b');
                }
            }
            this.lengthBySeq.set(sequenced.seq, lengths);
        }
    }

    private join(from: number, format: SummaryFormat): void {
        const source = this.peer(from);
        const codec = this.summaryCodecs.get(format) ?? assert.fail('missing codec');
        const bytes = JSON.stringify(codec.encode(source.manager.getSummaryData(), this.encodingContext));
        const peer = this.addPeer();
        const index = this.peers.length - 1;
        peer.manager.loadSummaryData(codec.decode(JSON.parse(bytes), { idCompressor: this.compressor, isSummary: true }));
        peer.processed = source.processed;
        peer.lastSeq = source.lastSeq;
        this.clientRefSeq[index] = source.lastSeq;
        this.rows.push(['join', String(index), String(from), String(format), bytes]);
        this.snapshot(index);
    }

    private commitRow(commit: GraphCommit<ModularChangeset>): string[] {
        return [this.encodeRevision(commit.revision), this.changeBytes(commit.change, commit.revision)];
    }

    private snapshot(index: number): void {
        const manager = this.peer(index).manager;
        const latest = manager.getLatestSequenceNumber();
        this.rows.push(['peer', String(index), String(latest), String(manager.getLongestBranchLength())]);
        this.rows.push(['trunk', String(index), ...manager.getTrunkCommits('main').flatMap(c => this.commitRow(c))]);
        const local = manager.getLocalBranch('main');
        this.rows.push(['local', String(index), ...this.commitRow(local.getHead()), ...manager.getLocalCommits('main').flatMap(c => this.commitRow(c))]);
        for (const [f, fork] of this.peer(index).forks.entries()) {
            if (fork !== undefined) {
                this.rows.push(['fork', String(index), String(f), ...this.commitRow(fork.getHead())]);
            }
        }
        if (this.summarizable(index)) {
            const data = manager.getSummaryData();
            this.rows.push(['summary', String(index), ...summaryFormats.map(format => {
                const codec = this.summaryCodecs.get(format) ?? assert.fail('missing codec');
                return JSON.stringify(codec.encode(data, this.encodingContext));
            })]);
        }
    }
}

export function run(scenario: Scenario): string[][] {
    const world = new World(scenario.peers);
    for (const action of scenario.actions) {
        world.execute(action);
    }
    return world.rows;
}
