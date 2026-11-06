/// feature-libraries/modular-schema/modularChangeUtils.ts.
public final class CrossFieldTable<Value, Field: Hashable> {
    var sources: ChangeAtomIdRangeMap<Value>
    var destinations: ChangeAtomIdRangeMap<Value>
    var sourceDependents: ChangeAtomIdRangeMap<Field>
    var destinationDependents: ChangeAtomIdRangeMap<Field>
    public private(set) var invalidatedFields: [Field] = []
    private var invalidatedSet: Set<Field> = []
    public init(context: BTreeStorageContext = BTreeStorageContext()) {
        sources = ChangeAtomIdRangeMap(context: context)
        destinations = ChangeAtomIdRangeMap(context: context)
        sourceDependents = ChangeAtomIdRangeMap(context: context)
        destinationDependents = ChangeAtomIdRangeMap(context: context)
    }
    func takeInvalidatedFields() -> [Field] {
        let result = invalidatedFields
        invalidatedFields = []
        invalidatedSet = []
        return result
    }
    func removeInvalidated(_ field: Field) {
        invalidatedSet.remove(field)
        invalidatedFields.removeAll { $0 == field }
    }

    func invalidate(_ field: Field) {
        if invalidatedSet.insert(field).inserted {
            invalidatedFields.append(field)
        }
    }

    public func resetDependencies() {
        invalidatedFields.removeAll(keepingCapacity: true)
        invalidatedSet.removeAll(keepingCapacity: true)
        sourceDependents.clear()
        destinationDependents.clear()
    }
}

/// feature-libraries/modular-schema/modularChangeUtils.ts: typed native counterpart
/// of CrossFieldManagerI. Owner callbacks implement node and key relocation.
public class CrossFieldManagerI<Value, Field: Hashable>: CrossFieldManager {
    public let table: CrossFieldTable<Value, Field>
    private let field: Field
    let allowInvalidation: Bool
    private let moveNode: (ChangeAtomId) -> Void
    private let relocateKey: (CrossFieldTarget, RevisionTag?, Double, Int) throws -> Void

    public init(table: CrossFieldTable<Value, Field>, field: Field, allowInvalidation: Bool = true,
                onMoveIn: @escaping (ChangeAtomId) -> Void,
                moveKey: @escaping (CrossFieldTarget, RevisionTag?, Double, Int) throws -> Void) {
        self.table = table
        self.field = field
        self.allowInvalidation = allowInvalidation
        moveNode = onMoveIn
        relocateKey = moveKey
    }

    public func get(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, addDependency: Bool) -> CrossFieldRange<Value> {
        let key = ChangeAtomId(localId: id, revision: revision)
        if addDependency {
            if target == .source {
                table.sourceDependents.set(key, count: count, value: field)
            } else {
                table.destinationDependents.set(key, count: count, value: field)
            }
        }
        return target == .source ? table.sources.getFirst(key, count: count) : table.destinations.getFirst(key, count: count)
    }

    public func set(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, value: Value, invalidateDependents: Bool) throws {
        if invalidateDependents && allowInvalidation {
            var offset = 0
            while offset < count {
                let key = ChangeAtomId(localId: id + Double(offset), revision: revision)
                let dependent = target == .source
                    ? table.sourceDependents.getFirst(key, count: count - offset)
                    : table.destinationDependents.getFirst(key, count: count - offset)
                if let field = dependent.value {
                    table.invalidate(field)
                }
                offset += dependent.length
            }
        }
        let key = ChangeAtomId(localId: id, revision: revision)
        if target == .source {
            table.sources.set(key, count: count, value: value)
        } else {
            table.destinations.set(key, count: count, value: value)
        }
    }

    public func onMoveIn(_ id: ChangeAtomId) {
        moveNode(id)
    }

    public func moveKey(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int) throws {
        try relocateKey(target, revision, id, count)
    }
}
