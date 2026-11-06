import { Random } from '../random.js';
import { World, summaryFormats, type Action, type EditSpec, type FieldKey, type Lengths, type Scenario } from './world.js';

const maxJoins = 2;

// A fresh edit's effect on its own peer's view; matches World.delta of the built change.
function applySpec(lengths: Lengths, spec: EditSpec): void {
    const other: FieldKey = spec.field === 'a' ? 'b' : 'a';
    if (spec.kind === 'insert') {
        lengths[spec.field] += spec.count;
    } else if (spec.kind === 'remove') {
        lengths[spec.field] -= spec.count;
    } else if (spec.kind === 'crossMove') {
        lengths[spec.field] -= spec.count;
        lengths[other] += spec.count;
    }
}

function makeSpec(random: Random, lengths: Lengths): EditSpec {
    const field: FieldKey = random.pick(['a', 'b']);
    const other: FieldKey = field === 'a' ? 'b' : 'a';
    const length = lengths[field];
    let kind = random.pick<EditSpec['kind']>(['insert', 'insert', 'remove', 'move', 'crossMove', 'nested']);
    // Every non-insert edit addresses an existing node.
    if (length === 0) {
        kind = 'insert';
    }
    const metadata = random.int(4) === 0 ? 1 + random.int(3) : 0;
    const spec: EditSpec = { kind, field, index: 0, count: 1 + random.int(3), destination: 0, metadata };
    if (kind === 'insert') {
        spec.index = random.int(length + 1);
        return spec;
    }
    spec.index = random.int(length);
    if (kind !== 'nested') {
        spec.count = Math.min(spec.count, length - spec.index);
    }
    if (kind === 'move') {
        spec.destination = random.int(length + 1);
    }
    if (kind === 'crossMove') {
        spec.destination = random.int(lengths[other] + 1);
    }
    return spec;
}

function editors(world: World): number[] {
    // Peer 0 is the observer: it never edits, so it can always summarize.
    return world.peers.map((_, index) => index).filter(index => index !== 0);
}

function choose(world: World, random: Random, joins: number): Action | undefined {
    const roll = random.int(100);
    const peerCount = world.peers.length;
    if (roll < 26) {
        const peer = random.pick(editors(world));
        const lengths = world.viewLengths(peer);
        const count = random.int(4) === 0 ? 2 + random.int(2) : 1;
        const edits: EditSpec[] = [];
        for (let i = 0; i < count; i++) {
            const spec = makeSpec(random, lengths);
            applySpec(lengths, spec);
            edits.push(spec);
        }
        return { type: 'edit', peer, edits };
    }
    if (roll < 36) {
        return { type: 'noop', peer: random.int(peerCount) };
    }
    if (roll < 60) {
        const ready = world.peers.map((p, index) => p.outbox.length > 0 ? index : -1).filter(index => index >= 0);
        if (ready.length > 0) {
            return { type: 'sequence', peer: random.pick(ready) };
        }
    }
    if (roll < 92) {
        const behind = world.peers.map((p, index) => p.processed < world.sequenced.length ? index : -1).filter(index => index >= 0);
        if (behind.length === 0) {
            return undefined;
        }
        const peer = random.pick(behind);
        return { type: 'deliver', peer, split: splitFor(world, peer, random) };
    }
    if (roll < 94) {
        const value = random.pick<boolean | number>([true, false, 0, 1, 2, 4]);
        return { type: 'retention', peer: random.int(peerCount), value };
    }
    if (roll < 98) {
        const peer = random.int(peerCount);
        const live = world.peer(peer).forks.map((fork, index) => fork === undefined ? -1 : index).filter(index => index >= 0);
        if (live.length === 0 || random.int(3) === 0) {
            return { type: 'fork', peer };
        }
        const fork = random.pick(live);
        return random.int(2) === 0 ? { type: 'rebaseFork', peer, fork } : { type: 'disposeFork', peer, fork };
    }
    const sources = world.peers.map((_, index) => world.summarizable(index) ? index : -1).filter(index => index >= 0);
    if (joins >= maxJoins || sources.length === 0) {
        return undefined;
    }
    return { type: 'join', from: random.pick(sources), format: random.pick(summaryFormats) };
}

function splitFor(world: World, peer: number, random: Random): number {
    const message = world.sequenced[world.peer(peer).processed]?.message;
    if (message === undefined || message.kind !== 'op' || message.commits.length < 2 || random.int(2) === 0) {
        return 0;
    }
    return 1 + random.int(message.commits.length - 1);
}

/**
 * Generates a scenario by running it on the real TS EditManagers, so each peer's edits are valid
 * in that peer's local view. The returned rows are the TS records for the scenario.
 */
export function generate(seed: number): { scenario: Scenario; rows: string[][] } {
    const random = new Random(seed * 7919 + 3);
    const peers = 2 + random.int(3);
    const world = new World(peers);
    const actions: Action[] = [];
    const perform = (action: Action): void => {
        world.execute(action);
        actions.push(action);
    };
    const steps = 40 + random.int(100);
    let joins = 0;
    for (let step = 0; step < steps; step++) {
        const action = choose(world, random, joins);
        if (action === undefined) {
            continue;
        }
        if (action.type === 'join') {
            joins += 1;
        }
        perform(action);
    }
    // Drain: every peer reports, every message is sequenced, and every peer catches up.
    for (let index = 0; index < world.peers.length; index++) {
        perform({ type: 'noop', peer: index });
    }
    for (let index = 0; index < world.peers.length; index++) {
        while (world.peer(index).outbox.length > 0) {
            perform({ type: 'sequence', peer: index });
        }
    }
    for (let index = 0; index < world.peers.length; index++) {
        while (world.peer(index).processed < world.sequenced.length) {
            perform({ type: 'deliver', peer: index, split: splitFor(world, index, random) });
        }
    }
    for (let index = 0; index < world.peers.length; index++) {
        perform({ type: 'snapshot', peer: index });
    }
    return { scenario: { seed, peers, actions }, rows: world.rows };
}
