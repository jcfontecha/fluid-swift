/** Pinned client.obliterateFarm.spec.ts workload, not the production differential protocol. */
import { TestClient } from '../../node_modules/@fluidframework/merge-tree/lib/test/testClient.js';
import { generateClientNames, runMergeTreeOperationRunner } from '../../node_modules/@fluidframework/merge-tree/lib/test/mergeTreeOperationRunner.js';
import { annotateWithField, generateInsertWithField, insertAvoidField, insertField, obliterateField, obliterateFieldZeroLength } from '../../node_modules/@fluidframework/merge-tree/lib/test/obliterateOperations.js';

// These belong to sequence's SharedString fuzz suite, NOT client.obliterateFarm.
// Do not transfer seeds across different random generators/workloads.
export const sharedStringKnownBugs = new Map([
    [51, 'AB#7220'],
    [71, 'AB#35446'],
    [68, 'AB#45138'],
]);

export async function runObliterateFarm(first: number, last: number): Promise<void> {
    // The pinned npm merge-tree test helpers depend on this unpublished workspace package.
    // Keep the import dynamic so the production farm needs no upstream test installation.
    const packageName = '@fluid-private/stochastic-test-utils';
    const stochastic: { makeRandom: (...seeds: [number, number, number, number]) => Parameters<typeof runMergeTreeOperationRunner>[0] } = await import(packageName);
    const names = generateClientNames();
    for (let seed = first; seed <= last; seed++) {
        for (let minLength = 1; minLength <= 512; minLength *= 2) {
            for (const obliterate of [obliterateField, obliterateFieldZeroLength]) {
                const random = stochastic.makeRandom(0xdeadbeef, 0xfeedbed, minLength, seed);
                const initial = new TestClient({
                    mergeTreeEnableObliterate: true,
                    mergeTreeEnableSidedObliterate: true,
                    mergeTreeEnableAnnotateAdjust: true,
                });
                initial.startOrUpdateCollaboration(names[0]!);
                initial.updateMinSeq(0);
                const clients = [initial];
                for (let index = 1; index < 3; index++)
                    clients.push(await TestClient.createFromClientSnapshot(initial, names[index]!));
                runMergeTreeOperationRunner(random, 0, clients, minLength, {
                    rounds: 8,
                    opsPerRoundRange: { min: 1, max: 128 },
                    growthFunc: input => input * 2,
                    operations: [annotateWithField, insertAvoidField, insertField, obliterate],
                    insertText: generateInsertWithField,
                });
            }
        }
        console.log(`upstream obliterate TS clients passed seed ${seed}`);
    }
}
