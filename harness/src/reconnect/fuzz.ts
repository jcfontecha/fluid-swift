import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { runOracle, startOrderingService } from './oracle.js';
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.split('=')[1] ?? 300);
const plant = process.argv.includes('--plant-divergence');
execFileSync('swift', ['build', '--scratch-path', '.build/reconnect', '--product', 'FluidReconnectPeer'], { cwd: '..', stdio: 'inherit' });
const service = await startOrderingService();
const peer = spawn('.build/reconnect/debug/FluidReconnectPeer', [], { cwd: '..', stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: peer.stdout })[Symbol.asyncIterator]();
try {
    for (let seed = 0; seed < count; seed++) {
        const expected = await runOracle(seed);
        service.reset();
        peer.stdin.write(JSON.stringify({ seed }) + '\n');
        const line = await lines.next();
        assert(!line.done, 'Swift peer exited');
        const actual: unknown = JSON.parse(line.value);
        if (plant && seed === 0)
            expected.events.push('planted');
        try {
            assert.deepEqual(actual, expected);
        }
        catch (error) {
            mkdirSync('traces/reconnect', { recursive: true });
            writeFileSync(`traces/reconnect/${seed}.json`, JSON.stringify({ seed, expected, actual }, null, 2));
            throw error;
        }
    }
    console.log(`reconnect: ${count} Swift/TS loader seeds passed (events, virtual delay, pending-op bytes, state)`);
}
finally {
    peer.kill();
    await service.close();
}
process.exit(0);
