import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { checkStateCheckpoints } from './state-oracle.js';
import { runRuntime, entropy, type RuntimeScenario } from './runtime-oracle.js';
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
await checkStateCheckpoints();
const self = process.argv.includes('--self');
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) {
    execFileSync('swift', ['build', '--scratch-path', '.build/h3', '--product', 'FluidPendingStatePeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
}
const child = self ? undefined : spawn(resolve(root, '.build/h3/release/FluidPendingStatePeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
function generateRuntime(seed: number): RuntimeScenario {
    const random = new Random(seed);
    const scenario: RuntimeScenario = { runtime: true, seed, uuids: entropy(seed), commands: [] };
    const add = (kind: RuntimeScenario['commands'][number]['kind'], client: number, count = 0, ids = 0, rebase = 0) => {
        scenario.commands.push({ kind, client, count, ids, rebase });
    };
    for (let round = 0; round < 8; round++) {
        const client = random.int(3);
        add('submit', client, 1 + random.int(3), 1 + random.int(5));
        add('disconnect', client);
        if (random.int(3) === 0) {
            if (random.int(2) === 0) add('reload', client);
            add('deliver', client);
        } else {
            add('drop', client);
        }
        add('submit', client, 1 + random.int(3), 1 + random.int(4));
        if (random.int(2) === 0) add('reload', client);
        add('connect', client, 0, 0, random.int(2) === 0 ? 0 : 100 + round);
        add('submit', (client + 1) % 3, 1 + random.int(2), random.int(4));
        add('deliver', client);
        add('duplicate', client);
    }
    return scenario;
}
let scenario: Scenario | RuntimeScenario | undefined;
let seed = 0;
try {
    for (; seed < count; seed++) {
        for (const candidate of [generate(seed), generateRuntime(seed)]) {
        scenario = candidate;
        const expected = 'runtime' in scenario ? await runRuntime(scenario) : run(scenario);
        let actual: string;
        if (self) {
            actual = 'runtime' in scenario ? await runRuntime(scenario) : run(scenario);
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
    }
    console.log(`Pending-state scenario farm ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
} catch (error) {
    mkdirSync(resolve(root, 'harness/traces/pendingstate'), { recursive: true });
    writeFileSync(resolve(root, `harness/traces/pendingstate/${seed}.json`), JSON.stringify({ seed, scenario, error: String(error) }, null, 2));
    throw error;
} finally {
    child?.kill();
}
