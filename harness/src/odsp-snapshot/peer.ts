import { spawn, type ChildProcessByStdio } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import {
    tsParseSnapshot,
    tsParseTree,
    tsWriteSnapshot,
    tsWriteTree,
    type Outcome,
    type RawElement,
    type SnapshotSpec,
} from './oracle.js';

/**
 * A codec implementation under test. Every method returns the JSON text of an `Outcome`, so key
 * order (which is observable: `Object.keys` order of `trees` and `blobs`) is compared exactly.
 */
export interface Peer {
    writeSnapshot(spec: SnapshotSpec): Promise<string>;
    parseSnapshot(hex: string): Promise<string>;
    writeTree(root: RawElement[]): Promise<string>;
    parseTree(hex: string): Promise<string>;
    close(): void;
}

/** The TS oracle behind the same interface; `--self` runs the whole harness against it. */
export class OraclePeer implements Peer {
    async writeSnapshot(spec: SnapshotSpec): Promise<string> {
        return JSON.stringify(tsWriteSnapshot(spec));
    }
    async parseSnapshot(hex: string): Promise<string> {
        return JSON.stringify(tsParseSnapshot(hex));
    }
    async writeTree(root: RawElement[]): Promise<string> {
        return JSON.stringify(tsWriteTree(root));
    }
    async parseTree(hex: string): Promise<string> {
        return JSON.stringify(tsParseTree(hex));
    }
    close(): void {}
}

const RESPONSE_TIMEOUT_MS = 30000;

/** The Swift `FluidOdspSnapshotPeer`: newline-delimited `{method, params}` in, one Outcome per line out. */
export class ProcessPeer implements Peer {
    private readonly child: ChildProcessByStdio<Writable, Readable, null>;
    private readonly lines: AsyncIterator<string>;

    constructor(executable: string) {
        this.child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'inherit'] });
        this.lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
    }

    private async call(method: string, params: unknown): Promise<string> {
        this.child.stdin.write(`${JSON.stringify({ method, params })}\n`);
        let timer: NodeJS.Timeout | undefined;
        const response = await Promise.race([
            this.lines.next(),
            new Promise<never>((_, reject) => {
                timer = setTimeout(() => reject(new Error(`odsp-snapshot peer timeout on ${method}`)), RESPONSE_TIMEOUT_MS);
            }),
        ]).finally(() => clearTimeout(timer));
        if (response.done === true) throw new Error(`odsp-snapshot peer exited during ${method}`);
        return response.value;
    }

    writeSnapshot(spec: SnapshotSpec): Promise<string> {
        return this.call('writeSnapshot', spec);
    }
    parseSnapshot(hex: string): Promise<string> {
        return this.call('parseSnapshot', hex);
    }
    writeTree(root: RawElement[]): Promise<string> {
        return this.call('writeTree', root);
    }
    parseTree(hex: string): Promise<string> {
        return this.call('parseTree', hex);
    }
    close(): void {
        this.child.kill();
    }
}

export function outcomeOf(text: string): Outcome {
    const value: unknown = JSON.parse(text);
    if (typeof value === 'object' && value !== null && ('ok' in value || 'err' in value)) return value as Outcome;
    throw new Error(`peer reply is not an outcome: ${text.slice(0, 200)}`);
}
