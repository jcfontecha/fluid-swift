import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { run, type Scenario } from './oracle.js';
const root = resolve(import.meta.dirname, '../../..');
function generate(seed: number): Scenario {
    const random = new Random(seed);
    const scenario: Scenario = { snapshot: [[1, 'snapshot_[1]']], commands: [] };
    let minimumSequenceNumber = 0;
    for (let sequenceNumber = 2; sequenceNumber < 150; sequenceNumber++) {
        if (random.int(8) === 0) {
            minimumSequenceNumber = sequenceNumber - random.int(2);
        }
        const clientId = random.pick(['a', 'b', 'snapshot', 'lone\ud800']);
        const batchStartCsn = random.int(8);
        scenario.commands.push({ kind: 'process', batch: {
            sequenceNumber,
            minimumSequenceNumber,
            clientId,
            batchStartCsn,
            ...(random.int(2) === 0 ? { batchId: `${clientId}_[${batchStartCsn}]` } : {}),
        } });
        if (random.int(8) === 0) {
            scenario.commands.push({ kind: random.int(2) === 0 ? 'summary' : 'reload' });
        }
    }
    scenario.commands.push({ kind: 'summary' });
    return scenario;
}
const self = process.argv.includes('--self');
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) {
    execFileSync('swift', ['build', '--scratch-path', '.build/h3', '--product', 'FluidPendingStatePeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
}
const child = self ? undefined : spawn(resolve(root, '.build/h3/release/FluidPendingStatePeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
let scenario: Scenario | undefined;
let seed = 0;
try {
    for (; seed < count; seed++) {
        scenario = generate(seed);
        const expected = run(scenario);
        let actual: string;
        if (self) {
            actual = run(scenario);
        } else {
            assert(child && lines);
            child.stdin.write(JSON.stringify(scenario) + '\n');
            let timer: NodeJS.Timeout | undefined;
            const line = await Promise.race([
                lines.next(),
                new Promise<never>((_, reject) => {
                    timer = setTimeout(() => reject(Error('peer timeout')), 30000);
                }),
            ]).finally(() => clearTimeout(timer));
            assert(!line.done, 'peer exited');
            actual = line.value;
        }
        assert.equal(actual, expected, `seed ${seed}`);
    }
    console.log(`DuplicateBatchDetector ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
} catch (error) {
    mkdirSync(resolve(root, 'harness/traces/pendingstate'), { recursive: true });
    writeFileSync(resolve(root, `harness/traces/pendingstate/${seed}.json`), JSON.stringify({ seed, scenario, error: String(error) }, null, 2));
    throw error;
} finally {
    child?.kill();
}
