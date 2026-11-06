import FluidJS

/// feature-libraries/modular-schema/prune.ts.
public func pruneModularChangeset(_ change: ModularChangeset) throws -> ModularChangeset {
    var result = change
    result.nodeChanges = change.nodeChanges.clone()
    result.nodeToParent = change.nodeToParent.clone()
    result.nodeAliases = change.nodeAliases.clone()
    func pruneFields(_ fields: FieldChangeMap?) throws -> FieldChangeMap? {
        guard let fields else { return nil }
        var pruned = FieldChangeMap()
        for (key, field) in fields.entries {
            let payload = try field.change.pruned { id in
                let node = try nodeChangeFromId(result, id: id)
                let fields = try pruneFields(node.fieldChanges)
                let updated = node.copy()
                updated.fieldChanges = fields
                let canonical = try normalizeNodeId(id, aliases: result.nodeAliases)
                if fields == nil && updated.nodeExistsConstraint == nil && updated.nodeExistsConstraintOnRevert == nil {
                    result.nodeChanges.delete(canonical)
                    result.nodeToParent.delete(canonical)
                    return nil
                }
                result.nodeChanges.set(canonical, updated)
                return id
            }
            if !payload.isEmpty { pruned[key] = FieldChange(fieldKind: field.fieldKind, change: payload) }
        }
        return pruned.isEmpty ? nil : pruned
    }
    result.fieldChanges = try pruneFields(change.fieldChanges) ?? FieldChangeMap()
    return result
}

func effectiveModularChange(_ change: ModularChangeset) throws -> ModularChangeset {
    guard (change.constraintViolationCount ?? 0) > 0 else { return change }
    func muteFields(_ fields: FieldChangeMap) throws -> FieldChangeMap {
        var result = FieldChangeMap()
        let detach: FilterDetachFunc = { _, count, _, _ in .init(length: count, value: .init(action: .remove, shouldRemoveChild: false)) }
        let attach: FilterAttachFunc = { _, count, _, _ in .init(length: count, value: .init(action: .remove)) }
        for (key, field) in fields.entries {
            let muted: FieldChangeset
            switch field.change {
            case .sequence(let marks): muted = .sequence(try filterSequence(marks, preserveOtherEdits: false, filterDetach: detach, filterAttach: attach))
            case .optional(let optional): muted = .optional(try filterOptional(optional, preserveOtherEdits: false, filterDetach: detach, filterAttach: attach))
            case .generic, .noChange: muted = field.change
            }
            result[key] = FieldChange(fieldKind: field.fieldKind, change: muted)
        }
        return result
    }
    var result = change
    result.crossFieldKeys = newCrossFieldKeyTable(context: change.context)
    result.fieldChanges = try muteFields(change.fieldChanges)
    result.nodeChanges = try change.nodeChanges.mapValues { node, _ in
        guard let node else { throw JSONDecodingError("missing node") }
        guard let fields = node.fieldChanges else { return node }
        let result = node.copy()
        result.fieldChanges = try muteFields(fields)
        return result
    }
    return result
}
