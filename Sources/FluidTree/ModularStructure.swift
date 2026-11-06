import FluidJS

func revisionStructure(_ revision: RevisionTag?) -> JSONValue {
    guard let revision else { return treeStructureUndefined }
    switch revision {
    case .root: return .string("root")
    case .compressed(let id): return .number(id)
    }
}
func atomStructure(_ atom: ChangeAtomId) -> JSONValue {
    var properties: [(JSString, JSONValue)] = [("localId", .number(atom.localId))]
    if atom.includesRevision {
        if atom.propertyOrder == .revisionFirst { properties.insert(("revision", revisionStructure(atom.revision)), at: 0) }
        else { properties.append(("revision", revisionStructure(atom.revision))) }
    }
    return treeStructureObject(properties)
}
func atomKeyStructure(_ atom: ChangeAtomId) -> JSONValue { treeStructureArray([revisionStructure(atom.revision), .number(atom.localId)]) }
func fieldIdStructure(_ field: FieldId) -> JSONValue {
    treeStructureObject([("nodeId", field.nodeId.map(atomStructure) ?? treeStructureUndefined), ("field", .string(field.field))])
}
private func effectValue(_ effect: SequenceMarkEffect, property: SequenceProperty) -> JSONValue {
    if property == .type {
        let name: String
        switch effect.kind {
        case .noop: return treeStructureUndefined
        case .insert: name = "Insert"
        case .remove: name = "Remove"
        case .moveIn: name = "MoveIn"
        case .moveOut: name = "MoveOut"
        case .rename: name = "Rename"
        case .attachAndDetach: name = "AttachAndDetach"
        }
        return .string(JSString(name))
    }
    switch effect.kind {
    case .rename(let id):
        if property == .idOverride { return atomStructure(id) }
    case .attachAndDetach(let attach, let detach):
        if property == .attach { return effectStructure(attach) }
        if property == .detach { return effectStructure(detach) }
    case .insert(let id, let revision), .remove(let id, let revision, _), .moveIn(let id, let revision, _), .moveOut(let id, let revision, _, _):
        if property == .id { return .number(id) }
        if property == .revision { return revisionStructure(revision) }
    case .noop: break
    }
    if property == .finalEndpoint {
        switch effect.kind {
        case .moveIn(_, _, let endpoint), .moveOut(_, _, let endpoint, _): return endpoint.map(atomStructure) ?? treeStructureUndefined
        default: return effect.extraEndpoint.map(atomStructure) ?? treeStructureUndefined
        }
    }
    if property == .idOverride {
        switch effect.kind {
        case .remove(_, _, let override), .moveOut(_, _, _, let override): return override.map(atomStructure) ?? treeStructureUndefined
        default: return effect.extraOverride.map(atomStructure) ?? treeStructureUndefined
        }
    }
    return treeStructureUndefined
}
private func effectStructure(_ effect: SequenceMarkEffect) -> JSONValue {
    treeStructureObject(effect.propertyOrder.map { (JSString($0.name), effectValue(effect, property: $0)) })
}
private func markStructure(_ mark: SequenceMark) -> JSONValue {
    treeStructureObject(mark.propertyOrder.map { property in
        let value: JSONValue
        switch property {
        case .count: value = .number(Double(mark.count))
        case .cellId: value = mark.cellId.map(atomStructure) ?? treeStructureUndefined
        case .changes: value = mark.changes.map(atomStructure) ?? treeStructureUndefined
        default: value = effectValue(mark.effect, property: property)
        }
        return (JSString(property.name), value)
    })
}
private func registerStructure(_ register: RegisterId) -> JSONValue {
    switch register {
    case .active: return .string("self")
    case .detached(let atom): return atomStructure(atom)
    }
}
private func optionalStructure(_ change: OptionalChangeset) -> JSONValue {
    var properties: [(JSString, JSONValue)] = [
        ("moves", treeStructureArray(change.moves.map { treeStructureArray([atomStructure($0.src), atomStructure($0.dst)]) })),
        ("childChanges", treeStructureArray(change.childChanges.map { treeStructureArray([registerStructure($0.register), atomStructure($0.change)]) })),
    ]
    if change.childrenFirst { properties.swapAt(0, 1) }
    if let replace = change.valueReplace {
        var value: [(JSString, JSONValue)] = [("isEmpty", .bool(replace.isEmpty))]
        if replace.sourceFirst, let source = replace.src { value.append(("src", registerStructure(source))) }
        value.append(("dst", atomStructure(replace.dst)))
        if !replace.sourceFirst, let source = replace.src { value.append(("src", registerStructure(source))) }
        properties.append(("valueReplace", treeStructureObject(value)))
    }
    return treeStructureObject(properties)
}
private func fieldsStructure(_ fields: FieldChangeMap) -> JSONValue {
    .array([.string("map"), .array(fields.entries.map { key, field in
        let change: JSONValue
        switch field.change {
        case .sequence(let marks): change = treeStructureArray(marks.map(markStructure))
        case .optional(let optional): change = optionalStructure(optional)
        case .generic(let generic): change = generic.structure(key: { .number(Double($0)) }, value: atomStructure)
        case .noChange: change = .number(0)
        }
        return .array([.string(key), treeStructureObject([("fieldKind", .string(JSString(field.fieldKind.rawValue))), ("change", change)])])
    })])
}
private func nodeStructure(_ node: NodeChangeset) -> JSONValue {
    var properties: [(JSString, JSONValue)] = []
    for property in node.propertyOrder {
        switch property {
        case .fieldChanges: properties.append(("fieldChanges", node.fieldChanges.map(fieldsStructure) ?? treeStructureUndefined))
        case .nodeExistsConstraint: properties.append(("nodeExistsConstraint", node.nodeExistsConstraint.map { treeStructureObject([("violated", .bool($0.violated))]) } ?? treeStructureUndefined))
        case .nodeExistsConstraintOnRevert: properties.append(("nodeExistsConstraintOnRevert", node.nodeExistsConstraintOnRevert.map { treeStructureObject([("violated", .bool($0.violated))]) } ?? treeStructureUndefined))
        }
    }
    return treeStructureObject(properties)
}

/// Mirrors harness/src/tree/oracle.ts's tagged, lossless structural projection.
/// No key sorting or metadata omission is allowed in this comparison path.
public func modularStructure(_ change: ModularChangeset) throws -> JSONValue {
    var properties: [(JSString, JSONValue)] = [
        ("fieldChanges", fieldsStructure(change.fieldChanges)),
        ("nodeChanges", change.nodeChanges.structure(key: atomKeyStructure, value: nodeStructure)),
        ("nodeToParent", change.nodeToParent.structure(key: atomKeyStructure, value: fieldIdStructure)),
        ("nodeAliases", change.nodeAliases.structure(key: atomKeyStructure, value: atomStructure)),
        ("crossFieldKeys", change.crossFieldKeys.structure(key: { key in
            treeStructureObject([("target", .number(key.target == .source ? 0 : 1)), ("revision", revisionStructure(key.revision)), ("localId", .number(key.localId))])
        }, value: fieldIdStructure)),
    ]
    if let infos = change.revisions {
        properties.append(("revisions", treeStructureArray(infos.map { info in
            var properties: [(JSString, JSONValue)] = [("revision", revisionStructure(info.revision))]
            if info.includesRollbackOf { properties.append(("rollbackOf", revisionStructure(info.rollbackOf))) }
            return treeStructureObject(properties)
        })))
    }
    if let maxId = change.maxId { properties.append(("maxId", .number(maxId))) }
    if let count = change.constraintViolationCount { properties.append(("constraintViolationCount", .number(Double(count)))) }
    if let constraint = change.noChangeConstraint { properties.append(("noChangeConstraint", treeStructureObject([("violated", .bool(constraint.violated))]))) }
    if let constraint = change.noChangeConstraintOnRevert { properties.append(("noChangeConstraintOnRevert", treeStructureObject([("violated", .bool(constraint.violated))]))) }
    if change.builds != nil || change.refreshers != nil { throw JSONDecodingError("native chunk structural projection requires a concrete chunk implementation") }
    if let destroys = change.destroys { properties.append(("destroys", destroys.structure(key: atomKeyStructure, value: { .number(Double($0)) }))) }
    return treeStructureObject(properties)
}
