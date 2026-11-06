// Test adapter matching upstream sequence-field/utils.ts's two-pass field tests.
import { newChangeAtomIdRangeMap, type RevisionTag, type ChangesetLocalId, type ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { CrossFieldTarget, type CrossFieldManager } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/crossFieldQueries.js';
export class SequenceTestTable<T> implements CrossFieldManager<T> {
    private readonly src = newChangeAtomIdRangeMap<T>();
    private readonly dst = newChangeAtomIdRangeMap<T>();
    private readonly srcQueries = newChangeAtomIdRangeMap<boolean>();
    private readonly dstQueries = newChangeAtomIdRangeMap<boolean>();
    invalidated = false;
    get(target: CrossFieldTarget, revision: RevisionTag | undefined, id: ChangesetLocalId, count: number, dependency: boolean) {
        if (dependency) (target === CrossFieldTarget.Source ? this.srcQueries : this.dstQueries).set({ revision, localId: id }, count, true);
        return (target === CrossFieldTarget.Source ? this.src : this.dst).getFirst({ revision, localId: id }, count);
    }
    set(target: CrossFieldTarget, revision: RevisionTag | undefined, id: ChangesetLocalId, count: number, value: T, invalidate: boolean): void {
        const queries = target === CrossFieldTarget.Source ? this.srcQueries : this.dstQueries;
        if (invalidate && queries.getFirst({ revision, localId: id }, count).value !== undefined) this.invalidated = true;
        (target === CrossFieldTarget.Source ? this.src : this.dst).set({ revision, localId: id }, count, value);
    }
    onMoveIn(_id: ChangeAtomId): void {}
    moveKey(_target: CrossFieldTarget, _revision: RevisionTag | undefined, _id: ChangesetLocalId, _count: number): void {}
    reset(): void {
        this.invalidated = false;
        this.srcQueries.clear();
        this.dstQueries.clear();
    }
}
