import assert from 'node:assert/strict';
import { z } from 'zod';
import { SummaryType, type ISummaryTree, type SummaryObject } from '@fluidframework/driver-definitions/internal';

export const treeSchema: z.ZodType<ISummaryTree> = z.lazy(() => z.object({
    type: z.literal(SummaryType.Tree),
    tree: z.record(z.string(), entrySchema),
    unreferenced: z.literal(true).optional(),
    groupId: z.string().optional(),
}));
const entrySchema: z.ZodType<SummaryObject> = z.lazy(() => z.union([
    treeSchema,
    z.object({ type: z.literal(SummaryType.Blob), content: z.string() }),
    z.object({ type: z.literal(SummaryType.Handle), handle: z.string(), handleType: z.union([z.literal(SummaryType.Tree), z.literal(SummaryType.Blob), z.literal(SummaryType.Attachment)]) }),
    z.object({ type: z.literal(SummaryType.Attachment), id: z.string() }),
]));
export const responseSchema = z.object({ full: z.object({ summary: treeSchema }), gc: z.unknown() });

/** Storage-owned resolution: neither runtime is allowed to hide unresolved handles in its loader. */
export function materialize(summary: ISummaryTree, baseline: ISummaryTree): ISummaryTree {
    function lookup(path: string): SummaryObject {
        let result: SummaryObject = baseline;
        for (const part of path.split('/').slice(1)) {
            assert(result.type === SummaryType.Tree);
            const next: SummaryObject | undefined = result.tree[decodeURIComponent(part)];
            assert(next, `missing handle ${path}`);
            result = next;
        }
        return result;
    }
    function visit(entry: SummaryObject): SummaryObject {
        if (entry.type === SummaryType.Handle) return visit(lookup(entry.handle));
        if (entry.type !== SummaryType.Tree) return entry;
        return { ...entry, tree: Object.fromEntries(Object.entries(entry.tree).map(([name, value]) => [name, visit(value)])) };
    }
    const result = visit(summary);
    assert(result.type === SummaryType.Tree);
    return result;
}
