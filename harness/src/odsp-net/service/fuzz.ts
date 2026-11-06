import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { FakeOdsp, type WireTrace } from './fake.js';
import { runOracle } from './oracle.js';
import { createScenario } from './scenario.js';

// ODSP 3: the real TS OdspDocumentServiceFactory and the Swift one drive the same scripted fake ODSP
// endpoint; outcomes, HTTP requests and server-observed socket frames must be equal.
const self = process.argv.includes('--self');
const count = Number(process.argv.find(value => value.startsWith('--seeds='))?.split('=')[1] ?? 300);
const first = Number(process.argv.find(value => value.startsWith('--from='))?.split('=')[1] ?? 0);
const fake = new FakeOdsp(7091);
await fake.listen();
if (!self)
    execFileSync('swift', ['build', '--scratch-path', '.build/odsp-service', '--product', 'FluidOdspNetPeer'], { cwd: '..', stdio: 'inherit' });
const child = self ? undefined : spawn('../.build/odsp-service/debug/FluidOdspNetPeer', [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;

/** Each established connection is disposed by the script, so the server must see its disconnect_document. */
function connections(outcome: unknown): number {
    const steps = (outcome as { steps: unknown[][] }).steps;
    return steps.filter(step => step[0] === 'connected').length;
}

function canonical(value: unknown): unknown {
    return JSON.parse(JSON.stringify(value));
}

async function swiftRun(line: string): Promise<Record<string, unknown>> {
    assert(child && lines);
    child.stdin.write(line + '\n');
    const reply = await lines.next();
    assert(!reply.done, 'Swift peer exited');
    return JSON.parse(reply.value) as Record<string, unknown>;
}

function save(seed: number, expected: unknown, actual: unknown, expectedWire: WireTrace, actualWire: WireTrace): void {
    mkdirSync('traces/odsp-net-service', { recursive: true });
    writeFileSync(`traces/odsp-net-service/${seed}.json`, JSON.stringify({ scenario: createScenario(seed, fake.origin), expected, actual, expectedWire, actualWire }, null, 1));
}

/** What each seed exercised, so a green run states its coverage. */
const tally = new Map<string, number>();
function bump(label: string): void {
    tally.set(label, (tally.get(label) ?? 0) + 1);
}
function record(scenario: ReturnType<typeof createScenario>, outcome: unknown): void {
    const steps = (outcome as { steps: unknown[][] }).steps;
    const fault = scenario.server.fault;
    bump(`kind ${scenario.kind}/${scenario.loadPath}`);
    bump(fault === null ? 'fault none' : `fault ${fault.target}:${fault.status}`);
    const last = steps[steps.length - 1];
    bump(last?.[0] === 'error' ? `ends error ${JSON.stringify(last[1])}` : 'ends ok');
    for (const step of steps)
        bump(`step ${String(step[0])}`);
}

let failures = 0;
try {
    for (let seed = first; seed < first + count; seed++) {
        const scenario = createScenario(seed, fake.origin);
        fake.reset(scenario);
        const expected = canonical(await runOracle(scenario));
        const expectedWire = await fake.take(connections(expected));
        fake.reset(scenario);
        const actual = canonical(self ? await runOracle(scenario) : await swiftRun(JSON.stringify({ service: scenario })));
        const actualWire = await fake.take(connections(expected));
        record(scenario, expected);
        try {
            assert.deepStrictEqual(actual, expected, `outcome seed ${seed}`);
            assert.deepStrictEqual(actualWire.http, expectedWire.http, `HTTP requests seed ${seed}`);
            assert.deepStrictEqual(actualWire.socket, expectedWire.socket, `socket frames seed ${seed}`);
        }
        catch (error) {
            save(seed, expected, actual, expectedWire, actualWire);
            failures++;
            if (failures === 1 || process.argv.includes('--all'))
                console.error(error instanceof Error ? error.message.slice(0, 4000) : error);
            if (!process.argv.includes('--all'))
                throw error;
        }
    }
    if (failures > 0)
        throw new Error(`${failures} seeds failed`);
    if (process.argv.includes('--coverage'))
        console.log([...tally].sort().map(([label, n]) => `${n}\t${label}`).join('\n'));
    console.log(`odsp-service ${self ? 'TS self-check' : 'Swift-vs-TS'}: ${count} seeds passed (load, create, create-empty; HTTP and socket traces byte-compared)`);
}
finally {
    child?.kill();
    await fake.close();
}
process.exit(0);
