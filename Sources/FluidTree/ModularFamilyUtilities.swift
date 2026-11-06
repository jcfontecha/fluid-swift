import FluidJS

/// core/tree/delta.ts: chunk lifecycle operations at the delta root.
public struct DeltaDetachedNodeBuild {
    public let id: DeltaDetachedNodeId
    public let trees: any TreeChunk
}
public struct DeltaDetachedNodeDestruction {
    public let id: DeltaDetachedNodeId
    public let count: Int
}
public struct DeltaRoot {
    public var fields: DeltaFieldMap?
    public var global: [DeltaDetachedNodeChanges]?
    public var rename: [DeltaDetachedNodeRename]?
    public var build: [DeltaDetachedNodeBuild]?
    public var destroy: [DeltaDetachedNodeDestruction]?
    public var refreshers: [DeltaDetachedNodeBuild]?
    public init() {}
}

extension FieldChangeset {
    func replacingRevisions<R: RevisionReplacer>(_ replacer: R) throws -> FieldChangeset {
        switch self {
        case .sequence(let change): return .sequence(try replaceSequenceRevisions(change, replacer: replacer))
        case .optional(let change): return .optional(try replaceOptionalRevisions(change) { try replacer.getUpdatedAtomId($0, count: 1) })
        case .generic(let change): return .generic(try replaceGenericRevisions(change, replacer: replacer))
        case .noChange: return self
        }
    }
    func delta(fromChild: (ChangeAtomId) throws -> DeltaFieldMap) throws -> FieldChangeDelta {
        switch self {
        case .sequence(let change): return try SequenceFieldChangeHandler().intoDelta(change, fromChild: fromChild)
        case .optional(let change): return try OptionalChangeHandler().intoDelta(change, fromChild: fromChild)
        case .generic(let change): return try GenericChangeHandler().intoDelta(change, fromChild: fromChild)
        case .noChange: return FieldChangeDelta()
        }
    }
    func removedRoots(fromChild: (ChangeAtomId) throws -> [DeltaDetachedNodeId]) throws -> [DeltaDetachedNodeId] {
        switch self {
        case .sequence(let change): return try SequenceFieldChangeHandler().relevantRemovedRoots(change, fromChild: fromChild)
        case .optional(let change): return try OptionalChangeHandler().relevantRemovedRoots(change, fromChild: fromChild)
        case .generic(let change): return try GenericChangeHandler().relevantRemovedRoots(change, fromChild: fromChild)
        case .noChange: return []
        }
    }
}

extension ModularChangeFamily {
    /// Ordered set of revisions (core Set iteration order is meaningful).
    public func getRevisions(_ change: ModularChangeset) -> [RevisionTag?] {
        guard let infos = change.revisions, !infos.isEmpty else { return [nil] }
        var seen: Set<RevisionTag> = []
        return infos.compactMap { seen.insert($0.revision).inserted ? $0.revision : nil }.map(Optional.some)
    }
    public func changeRevision<R: RevisionReplacer>(_ change: ModularChangeset, replacer: R) throws -> ModularChangeset {
        func fields(_ input: FieldChangeMap) throws -> FieldChangeMap {
            let result = FieldChangeMap()
            for (key, field) in input.entries { result[key] = FieldChange(fieldKind: field.fieldKind, change: try field.change.replacingRevisions(replacer)) }
            return result
        }
        func replaceMap<Value>(_ input: ChangeAtomIdBTree<Value>, mapValue: (Value) throws -> Value) throws -> ChangeAtomIdBTree<Value> {
            let result: ChangeAtomIdBTree<Value> = newChangeAtomIdBTree(context: context)
            for (id, value) in input.entries {
                guard let value else { throw JSONDecodingError("missing atom-map value") }
                let newId = try replacer.getUpdatedAtomId(id, count: 1)
                result.set(newId, try mapValue(value))
            }
            return result
        }
        var result = change
        result.fieldChanges = try fields(change.fieldChanges)
        result.nodeChanges = try replaceMap(change.nodeChanges) { node in
            let result = node.copy()
            result.fieldChanges = try node.fieldChanges.map(fields)
            return result
        }
        result.nodeToParent = try replaceMap(change.nodeToParent) { field in
            let canonical = try normalizeFieldId(field, aliases: change.nodeAliases)
            return FieldId(nodeId: try canonical.nodeId.map { try replacer.getUpdatedAtomId($0, count: 1) }, field: canonical.field)
        }
        result.nodeAliases = newChangeAtomIdBTree(context: context)
        result.crossFieldKeys = newCrossFieldKeyTable(context: context)
        for entry in change.crossFieldKeys.entries {
            let key = entry.start
            let updated = try replacer.getUpdatedAtomId(ChangeAtomId(localId: key.localId, revision: key.revision), count: entry.length)
            let field = try normalizeFieldId(entry.value, aliases: change.nodeAliases)
            let node = try field.nodeId.map { try replacer.getUpdatedAtomId($0, count: 1) }
            result.crossFieldKeys.set(CrossFieldKey(target: key.target, revision: updated.revision, localId: updated.localId), count: entry.length, value: FieldId(nodeId: node, field: field.field))
        }
        if let builds = change.builds { result.builds = try replaceMap(builds, mapValue: { $0 }) }
        if let destroys = change.destroys { result.destroys = try replaceMap(destroys, mapValue: { $0 }) }
        if let refreshers = change.refreshers { result.refreshers = try replaceMap(refreshers, mapValue: { $0 }) }
        result.revisions = [RevisionInfo(revision: replacer.updatedRevision)]
        return result
    }
    public func relevantRemovedRoots(_ change: ModularChangeset) throws -> [DeltaDetachedNodeId] {
        func visit(_ fields: FieldChangeMap) throws -> [DeltaDetachedNodeId] {
            try fields.entries.flatMap { _, field in
                try field.change.removedRoots { id in
                    let node = try nodeChangeFromId(change, id: id)
                    return try node.fieldChanges.map(visit) ?? []
                }
            }
        }
        return try visit(change.fieldChanges)
    }
    public func intoDelta(_ change: ModularChangeset) throws -> DeltaRoot {
        var global: [DeltaDetachedNodeChanges] = []
        var rename: [DeltaDetachedNodeRename] = []
        func visit(_ fields: FieldChangeMap) throws -> DeltaFieldMap {
            var result = DeltaFieldMap()
            for (key, field) in fields.entries {
                let delta = try field.change.delta { child in
                    let node = try nodeChangeFromId(change, id: child)
                    return try node.fieldChanges.map(visit) ?? DeltaFieldMap()
                }
                if let local = delta.local, !local.marks.isEmpty { result[key] = local }
                global.append(contentsOf: delta.global ?? [])
                rename.append(contentsOf: delta.rename ?? [])
            }
            return result
        }
        func copyChunks(_ nodes: ChangeAtomIdBTree<any TreeChunk>) throws -> [DeltaDetachedNodeBuild]? {
            var output: [DeltaDetachedNodeBuild] = []
            for (id, chunk) in nodes.entries {
                guard let chunk else { throw JSONDecodingError("missing chunk") }
                if chunk.topLevelLength > 0 {
                    chunk.referenceAdded()
                    output.append(DeltaDetachedNodeBuild(id: DeltaDetachedNodeId(id), trees: chunk))
                }
            }
            return output.isEmpty ? nil : output
        }
        var result = DeltaRoot()
        if (change.constraintViolationCount ?? 0) == 0 {
            let fields = try visit(change.fieldChanges)
            if !fields.isEmpty { result.fields = fields }
            if !global.isEmpty { result.global = global }
            if !rename.isEmpty { result.rename = rename }
        }
        if let builds = change.builds, !builds.isEmpty { result.build = try copyChunks(builds) }
        if let destroys = change.destroys, !destroys.isEmpty {
            result.destroy = try destroys.entries.map { id, count in
                guard let count else { throw JSONDecodingError("missing destroy count") }
                return DeltaDetachedNodeDestruction(id: DeltaDetachedNodeId(id), count: count)
            }
        }
        if let refreshers = change.refreshers, !refreshers.isEmpty { result.refreshers = try copyChunks(refreshers) }
        return result
    }
}
