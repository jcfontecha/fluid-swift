import { Random } from '../../random.js';

/** A request class the fake ODSP endpoint can fail. */
export type FaultTarget = 'treesLatest' | 'joinSession' | 'ops' | 'blob' | 'createBlob' | 'upload' | 'versions' | 'createFile' | 'push';

/**
 * `status` answers the first `times` matching requests with that HTTP status. `epoch` answers them
 * with 200 and a different `x-fluid-epoch` (for `push`, a different handshake epoch).
 */
export interface Fault {
    target: FaultTarget;
    status: number | 'epoch';
    times: number;
}

export interface SnapshotBlob {
    id: string;
    hex: string;
}

/** Server-side state: what the fake endpoint stores and how it answers. */
export interface ServerScript {
    format: 'json' | 'compact';
    sequenceNumber: number;
    snapshotOps: number;
    restOps: number;
    wrappedOps: boolean;
    appBlobs: SnapshotBlob[];
    extraBlob: SnapshotBlob;
    fault: Fault | null;
}

/**
 * One seeded scenario. Both the TS oracle and the Swift peer execute exactly these client steps
 * against an identically reset fake endpoint.
 */
export interface Scenario {
    seed: number;
    kind: 'load' | 'create' | 'createEmpty';
    origin: string;
    driveId: string;
    itemId: string;
    filePath: string;
    fileName: string;
    websocketToken: boolean;
    /** `versions` is the default loader path: getVersions(null, 1), then getSnapshotTree(version). */
    loadPath: 'snapshot' | 'versions';
    readBlobs: string[];
    snapshotTree: boolean;
    versions: number;
    connect: 'before' | 'after' | 'none';
    fetchFrom: number;
    fetchTo: number | null;
    submits: number;
    signal: boolean;
    summary: 'container' | 'channel' | 'none';
    createBlob: string | null;
    server: ServerScript;
    /** The resolve request's `X-CLP-Compliant-App` header value; null leaves the header out. */
    clp: boolean | null;
    /** Create-new only: the host sets `context` and `appName` on the resolved URL before createContainer. */
    hostContext: boolean;
}

const loadFaults: readonly FaultTarget[] = ['treesLatest', 'joinSession', 'ops', 'blob', 'createBlob', 'upload', 'versions', 'push'];
const createFaults: readonly FaultTarget[] = ['createFile', 'joinSession', 'ops', 'upload', 'push'];
const statuses: readonly (number | 'epoch')[] = [401, 401, 403, 404, 409, 'epoch', 'epoch', 429, 500];

function hexBytes(random: Random, length: number): string {
    let text = '';
    for (let index = 0; index < length; index++)
        text += random.int(256).toString(16).padStart(2, '0');
    return text;
}

function chooseFault(random: Random, targets: readonly FaultTarget[]): Fault | null {
    if (random.int(5) < 2)
        return null;
    const target = random.pick(targets);
    let status = random.pick(statuses);
    // Coherency 409 with a matching epoch retries with a 1-second backoff; keep those rare.
    if (status === 409 && random.int(4) !== 0)
        status = 'epoch';
    if (target === 'push' && status !== 'epoch')
        status = random.pick([400, 403, 404, 'epoch']);
    // A 500/429 on the delta feed is retried by getSingleOpBatch; a second failure keeps retrying.
    const times = status === 401 || status === 500 || status === 429 ? 1 + random.int(2) : 1;
    return { target, status, times };
}

export function createScenario(seed: number, origin: string): Scenario {
    const random = new Random(seed * 2654435761);
    const kinds: readonly Scenario['kind'][] = ['load', 'load', 'load', 'load', 'create', 'createEmpty'];
    const kind = random.pick(kinds);
    const sequenceNumber = kind === 'load' ? 3 + random.int(20) : 0;
    const snapshotOps = kind === 'load' ? random.int(3) : 0;
    const restOps = random.int(4);
    const appBlobs: SnapshotBlob[] = [];
    const blobCount = 1 + random.int(3);
    for (let index = 0; index < blobCount; index++)
        appBlobs.push({ id: `blob-${seed}-${index}`, hex: hexBytes(random, random.pick([0, 1, 7, 40])) });
    const extraBlob = { id: `extra-${seed}`, hex: hexBytes(random, 1 + random.int(9)) };
    const readBlobs: string[] = [];
    if (kind === 'load') {
        for (const blob of appBlobs) {
            if (random.int(2) === 0)
                readBlobs.push(blob.id);
        }
        if (random.int(2) === 0)
            readBlobs.push(extraBlob.id);
    }
    const latest = sequenceNumber + snapshotOps + restOps;
    const connect = random.pick(['before', 'after', 'after', 'none'] as const);
    const fetchFrom = sequenceNumber + 1 + random.int(snapshotOps + 1);
    // A fixed range ends within the stored ops; an empty range (TS fails it with 0x270) stays rare.
    const available = latest + 1 - fetchFrom;
    let fetchTo: number | null = null;
    if (random.int(2) === 0)
        fetchTo = available > 0 && random.int(8) !== 0 ? fetchFrom + 1 + random.int(available) : fetchFrom;
    const summary = connect === 'none' ? random.pick(['channel', 'none'] as const) : random.pick(['container', 'channel', 'none'] as const);
    return {
        seed,
        kind,
        origin,
        driveId: random.pick(['drive', 'b!Drive+Id', 'd/2']),
        itemId: `item-${seed}`,
        filePath: random.pick(['', 'folder', '/nested/path']),
        fileName: `file ${seed}`,
        websocketToken: random.int(2) === 0,
        loadPath: kind === 'load' && random.int(2) === 0 ? 'versions' : 'snapshot',
        readBlobs,
        snapshotTree: random.int(2) === 0,
        versions: kind === 'load' ? random.pick([0, 0, 1, 2]) : 0,
        connect,
        fetchFrom,
        fetchTo,
        submits: connect === 'none' ? 0 : random.int(3),
        signal: connect !== 'none' && random.int(2) === 0,
        summary: kind === 'createEmpty' ? 'container' : summary,
        createBlob: random.int(3) === 0 ? hexBytes(random, 1 + random.int(5)) : null,
        server: {
            format: random.pick(['json', 'compact']),
            sequenceNumber,
            snapshotOps,
            restOps,
            wrappedOps: random.int(2) === 0,
            appBlobs,
            extraBlob,
            fault: chooseFault(random, kind === 'load' ? loadFaults : createFaults),
        },
        // Drawn after every other field, so the earlier fields of each seed are unchanged.
        clp: random.pick([null, null, true, false]),
        hostContext: kind !== 'load' && random.int(2) === 0,
    };
}
