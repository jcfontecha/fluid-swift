import { GCSummaryStateTracker } from '../../node_modules/@fluidframework/container-runtime/lib/gc/gcSummaryStateTracker.js';
import { runGarbageCollection } from '../../node_modules/@fluidframework/container-runtime/lib/gc/gcReferenceGraphAlgorithm.js';
import type { IGarbageCollectionState } from '../../node_modules/@fluidframework/container-runtime/lib/gc/gcSummaryDefinitions.js';
export function scenario(seed: number) {
    const nodes: Record<string, string[]> = { '/': ['/a'] };
    for (const name of ['a', 'b', 'c', 'A', 'z', '10', '2', 'é', 'É', '🙂']) {
        nodes[`/${name}`] = (seed + name.charCodeAt(0)) % 3 === 0 ? ['/b', '/missing'] : [];
    }
    const mark = runGarbageCollection(nodes, ['/']);
    const state: IGarbageCollectionState = { gcNodes: {} };
    for (const [path, routes] of Object.entries(nodes)) {
        state.gcNodes[path] = { outboundRoutes: routes, ...(mark.deletedNodeIds.includes(path) ? { unreferencedTimestampMs: seed + 100 } : {}) };
    }
    return { nodes, state };
}
export async function run(seed: number) {
    const { nodes, state } = scenario(seed);
    const tracker = new GCSummaryStateTracker({ gcAllowed: true, gcVersionInBaseSnapshot: 3, gcVersionInEffect: 3 });
    const first = tracker.summarize(true, state, new Set(), []);
    const unacked = tracker.summarize(true, state, new Set(), []);
    await tracker.refreshLatestSummary({ isSummaryTracked: true, isSummaryNewer: true });
    const incremental = tracker.summarize(true, state, new Set(), []);
    const full = tracker.summarize(false, state, new Set(), []);
    return { mark: runGarbageCollection(nodes, ['/']), first, unacked, incremental, full };
}
