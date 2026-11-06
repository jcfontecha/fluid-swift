import type { OpSpaceCompressedId } from '@fluidframework/id-compressor';
import { compressor, type Node, type Scenario } from './oracle.js';
export function generate(seed: number): Scenario {
    let state = seed + 1;
    const next = (max: number) => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state % max;
    };
    const suffix = String(next(999));
    const names = ['N', 'S', 'B', 'Z', 'O', 'M', 'A'].map(n => n + suffix);
    const [N = '', S = '', B = '', Z = '', O = '', M = '', A = ''] = names;
    const types = [N, S, B, Z, O, M, A];
    const xOptional = next(2) === 0;
    const nestedSequence = next(2) === 0;
    const childType = next(2) === 0 ? N : S;
    const mapKind = ['Value', 'Optional', 'Sequence'][next(3)] ?? 'Sequence';
    const schema: Scenario['schema'] = {version: 1, nodes: {
        [N]: {leaf: 0}, [S]: {leaf: 1}, [B]: {leaf: 2}, [Z]: {leaf: 4},
        [O]: {object: {id: {kind: 'Identifier', types: [S]}, x: {kind: xOptional ? 'Optional' : 'Value', types: [N]}, nested: {kind: nestedSequence ? 'Sequence' : 'Optional', types}, children: {kind: 'Sequence', types: [childType]}}},
        [M]: {map: {kind: mapKind, types}},
        [A]: {object: {'': {kind: 'Sequence', types}}},
    }, root: {kind: 'Sequence', types}};
    const c = compressor();
    const stable = c.decompress(c.normalizeToSessionSpace(0 as OpSpaceCompressedId, c.localSessionId));
    function make(depth: number): Node {
        const kind = next(depth > 2 ? 4 : 7);
        const type = names[kind] ?? N;
        switch (kind) {
            case 0: return {type, value: next(100000) / 100, fields: []};
            case 1: return {type, value: ['hello', '😀', '\ud800', '__proto__', 'long repeated value'][next(5)] ?? '', fields: []};
            case 2: return {type, value: next(2) === 0, fields: []};
            case 3: return {type, value: null, fields: []};
            case 4: return {type, fields: [['id', [{type: S, value: [stable, 'custom-id', '00000001-0000-5000-8000-000000000000', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'][next(4)] ?? stable, fields: []}]], ['x', xOptional && next(2) === 0 ? [] : [{type: N, value: next(90), fields: []}]], ...(next(2) ? [['nested', Array.from({length: nestedSequence ? next(4) + 1 : 1}, () => make(depth + 1))]] satisfies [string, Node[]][] : []), ['children', Array.from({length: next(5)}, () => ({type: childType, value: childType === N ? next(123) : 's', fields: []}))]].filter(([, n]) => n.length > 0) as [string, Node[]][]};
            case 5: return {type, fields: Array.from({length: next(5)}, (_, i): [string, Node[]] => [['key', '__proto__', '0', 'constructor'][i] ?? 'k', Array.from({length: mapKind === 'Value' ? 1 : mapKind === 'Optional' ? 1 : next(4) + 1}, () => make(depth + 1))])};
            default: {
                const children = Array.from({length: next(6)}, () => make(depth + 1));
                return {type, fields: children.length ? [['', children]] : []};
            }
        }
    }
    return {seed, schema, fields: Array.from({length: mapKind === 'Value' ? 1 : mapKind === 'Optional' ? 1 : next(4) + 1}, () => Array.from({length: next(5)}, () => make(0)))};
}
