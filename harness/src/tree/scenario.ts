import { Random } from '../random.js';
import type { Edit, Scenario } from './oracle.js';

export function generate(seed: number): Scenario {
    const random = new Random(seed);
    const kinds: Edit['kind'][] = ['insert', 'remove', 'move', 'revive', 'set', 'clear', 'crossMove', 'nested'];
    return {
        seed,
        edits: [...kinds, ...Array.from({ length: 16 }, () => random.pick(kinds))].map(kind => ({
            kind,
            index: random.int(5),
            count: 1 + random.int(3),
            destination: random.int(12),
            field: random.pick(['a', 'b']),
        })),
    };
}
