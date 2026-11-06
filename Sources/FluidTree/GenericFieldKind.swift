import FluidJS

/// feature-libraries/modular-schema/genericFieldKindTypes.ts.
public typealias GenericChangeset = BTree<Int, ChangeAtomId>
public func newGenericChangeset(_ entries: [(Int, ChangeAtomId)] = [], context: BTreeStorageContext = BTreeStorageContext()) -> GenericChangeset {
    let result = GenericChangeset(context: context, compare: { $0 < $1 ? -1 : $0 > $1 ? 1 : 0 })
    for (index, node) in entries { result.set(index, node) }
    return result
}

/// feature-libraries/modular-schema/genericFieldKind.ts.
public func composeGenericChange(_ first: GenericChangeset, _ second: GenericChangeset, composeChild: NodeChangeComposer) throws -> GenericChangeset {
    let result = first.clone()
    for (index, node) in second.entries {
        guard let node else { throw JSONDecodingError("generic change requires node ID") }
        let composed = try result.get(index).map { try composeChild($0, node) } ?? node
        result.set(index, composed)
    }
    return result
}
public func rebaseGenericChange(_ change: GenericChangeset, over base: GenericChangeset, rebaseChild: NodeChangeRebaser) throws -> GenericChangeset {
    let result = newGenericChangeset(context: change.context)
    var nextIndex = 0
    while true {
        let newEntry = change.getPairOrNextHigher(nextIndex)
        let baseEntry = base.getPairOrNextHigher(nextIndex)
        if newEntry == nil && baseEntry == nil { return result }
        let newIndex = newEntry?.0 ?? Int.max
        let baseIndex = baseEntry?.0 ?? Int.max
        let index = min(newIndex, baseIndex)
        let newNode = newIndex == index ? newEntry?.1 : nil
        let baseNode = baseIndex == index ? baseEntry?.1 : nil
        if let rebased = try rebaseChild(newNode, baseNode, nil) { result.set(index, rebased) }
        guard index < Int.max else { throw JSONDecodingError("generic index overflow") }
        nextIndex = index + 1
    }
}
public func pruneGenericChange(_ change: GenericChangeset, pruneChild: (ChangeAtomId) throws -> ChangeAtomId?) throws -> GenericChangeset {
    let result = newGenericChangeset(context: change.context)
    for (index, node) in change.entries {
        guard let node else { throw JSONDecodingError("generic change requires node ID") }
        if let pruned = try pruneChild(node) { result.set(index, pruned) }
    }
    return result
}
public func replaceGenericRevisions<R: RevisionReplacer>(_ change: GenericChangeset, replacer: R) throws -> GenericChangeset {
    try change.mapValues { node, _ in
        guard let node else { throw JSONDecodingError("generic change requires node ID") }
        return try replacer.getUpdatedAtomId(node, count: 1)
    }
}

public struct GenericChangeHandler {
    public init() {}
    public func createEmpty(context: BTreeStorageContext = BTreeStorageContext()) -> GenericChangeset { newGenericChangeset(context: context) }
    public func isEmpty(_ change: GenericChangeset) -> Bool { change.isEmpty }
    public func getCrossFieldKeys(_ change: GenericChangeset) -> [CrossFieldKeyRange] { [] }
    public func getNestedChanges(_ change: GenericChangeset) throws -> [ChildChangeInfo] {
        try change.entries.map { _, node in
            guard let node else { throw JSONDecodingError("generic change requires node ID") }
            return ChildChangeInfo(nodeId: node, inputRootId: nil, detachId: nil)
        }
    }
    public func buildChildChanges(_ children: [(Int, ChangeAtomId)], context: BTreeStorageContext = BTreeStorageContext()) -> GenericChangeset {
        newGenericChangeset(children, context: context)
    }
    public func intoDelta(_ change: GenericChangeset, fromChild: (ChangeAtomId) throws -> DeltaFieldMap) throws -> FieldChangeDelta {
        var index = 0
        var marks: [DeltaMark] = []
        for (childIndex, child) in change.entries {
            guard let child else { throw JSONDecodingError("generic change requires node ID") }
            if index < childIndex { marks.append(DeltaMark(count: childIndex - index)) }
            marks.append(DeltaMark(count: 1, fields: try fromChild(child)))
            index = childIndex + 1
        }
        var result = FieldChangeDelta()
        result.local = DeltaFieldChanges(marks: marks)
        return result
    }
    public func relevantRemovedRoots(_ change: GenericChangeset, fromChild: (ChangeAtomId) throws -> [DeltaDetachedNodeId]) throws -> [DeltaDetachedNodeId] {
        try change.entries.flatMap { _, child in
            guard let child else { throw JSONDecodingError("generic change requires node ID") }
            return try fromChild(child)
        }
    }
}

/// feature-libraries/modular-schema/genericFieldKindCodecs.ts. Format 1 only.
public struct GenericFieldCodec {
    public init() {}
    public func encode(_ change: GenericChangeset, encodeNode: (ChangeAtomId) throws -> JSONValue) throws -> JSONValue {
        .array(try change.entries.map { index, child in
            guard let child else { throw JSONDecodingError("generic change requires node ID") }
            return .array([.number(Double(index)), try encodeNode(child)])
        })
    }
    public func decode(_ encoded: JSONValue, context: BTreeStorageContext = BTreeStorageContext(), decodeNode: (JSONValue) throws -> ChangeAtomId) throws -> GenericChangeset {
        let children = try encoded.asArray().map { value in
            let tuple = try value.asArray()
            guard tuple.count == 2 else { throw JSONDecodingError("expected generic [index,node]") }
            let index = try tuple[0].asInt()
            guard index >= 0 else { throw JSONDecodingError("negative generic index") }
            return (index, try decodeNode(tuple[1]))
        }
        return newGenericChangeset(children, context: context)
    }
}
