import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
const response = z.object({ jsonrpc: z.literal('2.0'), id: z.number(), result: z.unknown().optional(), error: z.object({ message: z.string() }).optional() });
export class Peer {
    private id = 0;
    private child;
    private lines;
    private errors = '';
    constructor(readonly kind: string, readonly trace: unknown[], readonly slot = 0) {
        const root = fileURLToPath(new URL('../../../', import.meta.url));
        if (kind !== 'ts' && kind !== 'swift')
            throw Error(`unknown peer ${kind}`);
        this.child = kind === 'ts' ? spawn(process.execPath, ['--import', 'tsx', root + 'harness/src/mergetree/oracle.ts'], { cwd: root + 'harness' }) : spawn(root + '.build/f1/debug/FluidMergeTreePeer', [], { cwd: root });
        this.child.on('error', e => {
            this.errors += String(e);
        });
        this.child.stderr.on('data', (b: Buffer) => {
            this.errors += b.toString();
        });
        this.lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
    }
    async call(method: string, params: unknown = {}) {
        const request = { jsonrpc: '2.0', id: ++this.id, method, params };
        this.trace.push({ slot: this.slot, kind: this.kind, request });
        this.child.stdin.write(JSON.stringify(request) + '\n');
        let timer: ReturnType<typeof setTimeout> | undefined;
        const line = await Promise.race([this.lines.next(), new Promise<never>((_, reject) => {
                timer = setTimeout(() => reject(Error('peer timeout ' + this.errors)), 10000);
            })]).finally(() => clearTimeout(timer));
        if (line.done)
            throw Error('peer exited ' + this.errors);
        const r = response.parse(JSON.parse(line.value));
        this.trace.push({ slot: this.slot, kind: this.kind, response: r });
        if (r.id !== this.id)
            throw Error('response id mismatch');
        if (r.error)
            throw Error(r.error.message);
        return r.result;
    }
    close() {
        this.child.kill();
    }
}
