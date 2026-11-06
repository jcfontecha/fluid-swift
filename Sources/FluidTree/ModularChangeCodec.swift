import FluidJS

/// core/rebase codec context. Chunk codecs own any schema-specific settings.
public struct ModularCodecContext {
    public var revision: RevisionTag?
    public var originatorId: String
    public var isSummary: Bool
    public init(revision: RevisionTag? = nil, originatorId: String, isSummary: Bool = false) {
        self.revision = revision
        self.originatorId = originatorId
        self.isSummary = isSummary
    }
}

/// Boundary to chunked-forest FieldBatchCodec and chunkFieldSingle. The modular
/// codec groups chunk IDs; the injected codec owns native chunk serialization.
public protocol ModularChunkCodec {
    func encode(_ chunks: [any TreeChunk], context: ModularCodecContext) throws -> JSONValue
    func decode(_ value: JSONValue, context: ModularCodecContext) throws -> [any TreeChunk]
}

/// feature-libraries/modular-schema/modularChangeCodecV1.ts and V2.ts.
/// Modular 3/4 use V1; modular 5 adds noChangeConstraint via V2.
public struct ModularChangeCodec {
    public let version: Int
    private let revisions: RevisionTagCodec
    private let atoms: ChangeAtomIdCodec
    private let sequence: SequenceFieldCodec
    private let optional: OptionalFieldCodec
    private let generic = GenericFieldCodec()
    private let chunks: (any ModularChunkCodec)?
    public let storageContext: BTreeStorageContext
    public init(version: Int, revisionTagCodec: RevisionTagCodec, storageContext: BTreeStorageContext = BTreeStorageContext(), chunks: (any ModularChunkCodec)? = nil) throws {
        guard [3, 4, 5].contains(version) else { throw JSONDecodingError("0xcc5: unsupported modular codec") }
        self.version = version
        self.revisions = revisionTagCodec
        atoms = ChangeAtomIdCodec(revisionTagCodec)
        sequence = try SequenceFieldCodec(version: version == 3 ? 2 : 3, revisionTagCodec: revisionTagCodec)
        optional = OptionalFieldCodec(revisionTagCodec)
        self.storageContext = storageContext
        self.chunks = chunks
    }
    public func encode(_ change: ModularChangeset, context: ModularCodecContext) throws -> JSONValue {
        guard change.destroys == nil else { throw JSONDecodingError("0x899: unexpected changeset with destroys") }
        var encoded = JSObject<JSONValue>()
        if let max = change.maxId { encoded["maxId"] = .number(max) }
        if let infos = change.revisions {
            if let implicit = context.revision {
                guard infos.count == 1, let info = infos.first, info.revision == implicit, info.rollbackOf == nil else {
                    throw JSONDecodingError("0x964: tagged change must contain only tagged revision")
                }
            } else {
                encoded["revisions"] = .array(try infos.map { info in
                    var value = JSObject<JSONValue>()
                    value["revision"] = try revisions.encode(info.revision)
                    if let rollback = info.rollbackOf { value["rollbackOf"] = try revisions.encode(rollback) }
                    return .object(value)
                })
            }
        }
        encoded["changes"] = try encodeFields(change.fieldChanges, owner: change, context: context)
        encoded["builds"] = try encodeDetachedNodes(change.builds, context: context)
        encoded["refreshers"] = try encodeDetachedNodes(change.refreshers, context: context)
        if let violations = change.constraintViolationCount { encoded["violations"] = .number(Double(violations)) }
        if version == 5, let constraint = change.noChangeConstraint { encoded["noChangeConstraint"] = constraintJSON(constraint.violated) }
        return .object(encoded)
    }
    private func encodeFields(_ fields: FieldChangeMap, owner: ModularChangeset, context: ModularCodecContext) throws -> JSONValue {
        .array(try fields.entries.map { key, field in
            func encodeNode(_ id: ChangeAtomId) throws -> JSONValue {
                let node = try nodeChangeFromId(owner, id: id)
                var encoded = JSObject<JSONValue>()
                if let fields = node.fieldChanges { encoded["fieldChanges"] = try encodeFields(fields, owner: owner, context: context) }
                if let constraint = node.nodeExistsConstraint { encoded["nodeExistsConstraint"] = constraintJSON(constraint.violated) }
                return .object(encoded)
            }
            let payload: JSONValue
            switch (field.fieldKind, field.change) {
            case (.sequence, .sequence(let marks)):
                payload = try sequence.encode(marks, revision: context.revision, encodeNode: encodeNode)
            case (.optional, .optional(let change)), (.required, .optional(let change)):
                payload = try optional.encode(change, revision: context.revision, encodeNode: encodeNode)
            case (.generic, .generic(let change)):
                payload = try generic.encode(change, encodeNode: encodeNode)
            case (.forbidden, .noChange), (.identifier, .noChange): payload = .number(0)
            default: throw JSONDecodingError("0x5ea: unsupported field kind/payload combination")
            }
            var encoded = JSObject<JSONValue>()
            encoded["fieldKey"] = .string(key)
            encoded["fieldKind"] = .string(JSString(field.fieldKind.rawValue))
            encoded["change"] = payload
            return .object(encoded)
        })
    }
    public func decode(_ encoded: JSONValue, context: ModularCodecContext) throws -> ModularChangeset {
        let object = try encoded.asObject()
        var decoded = ModularChangeset(context: storageContext)
        let maxId = try object["maxId"].map { try atoms.decode(.number(try $0.asNumber()), revision: nil, originatorId: context.originatorId).localId }
        var nextId = (maxId ?? -1) + 1
        decoded.fieldChanges = try decodeFields(encoded.member("changes"), parent: nil, owner: &decoded, nextId: &nextId, context: context)
        if let builds = object["builds"] { decoded.builds = try decodeDetachedNodes(builds, context: context) }
        if let refreshers = object["refreshers"] { decoded.refreshers = try decodeDetachedNodes(refreshers, context: context) }
        if let violations = object["violations"] { decoded.constraintViolationCount = try violations.asInt() }
        if let infos = object["revisions"] {
            decoded.revisions = try infos.asArray().map { value in
                let fields = try value.asObject()
                return RevisionInfo(revision: try revisions.decode(value.member("revision"), originatorId: context.originatorId), rollbackOf: try fields["rollbackOf"].map { try revisions.decode($0, originatorId: context.originatorId) })
            }
        } else if let revision = context.revision { decoded.revisions = [RevisionInfo(revision: revision)] }
        decoded.maxId = maxId
        if version == 5, let constraint = object["noChangeConstraint"] { decoded.noChangeConstraint = NoChangeConstraint(violated: try decodeConstraint(constraint)) }
        return decoded
    }
    private func decodeFields(_ encoded: JSONValue, parent: ChangeAtomId?, owner: inout ModularChangeset, nextId: inout Double, context: ModularCodecContext) throws -> FieldChangeMap {
        var result = FieldChangeMap()
        for value in try encoded.asArray() {
            let key = try value.member("fieldKey").asString()
            guard let kind = FieldKindIdentifier(rawValue: try value.member("fieldKind").asString().description) else { throw JSONDecodingError("0x9c1: unknown field kind") }
            let fieldId = FieldId(nodeId: parent, field: key)
            func decodeNode(_ encodedNode: JSONValue) throws -> ChangeAtomId {
                let id = ChangeAtomId(localId: nextId, revision: context.revision, propertyOrder: .revisionFirst, includesRevision: true)
                nextId += 1
                let properties = try encodedNode.asObject()
                var node = NodeChangeset()
                if let fields = properties["fieldChanges"] { node.fieldChanges = try decodeFields(fields, parent: id, owner: &owner, nextId: &nextId, context: context) }
                if let constraint = properties["nodeExistsConstraint"] { node.nodeExistsConstraint = NodeExistsConstraint(violated: try decodeConstraint(constraint)) }
                owner.nodeChanges.set(id, node)
                owner.nodeToParent.set(id, fieldId)
                return id
            }
            let payload = try value.member("change")
            let change: FieldChangeset
            switch kind {
            case .sequence: change = .sequence(try sequence.decode(payload, revision: context.revision, originatorId: context.originatorId, decodeNode: decodeNode))
            case .optional, .required: change = .optional(try optional.decode(payload, revision: context.revision, originatorId: context.originatorId, decodeNode: decodeNode))
            case .generic: change = .generic(try generic.decode(payload, context: storageContext, decodeNode: decodeNode))
            case .forbidden, .identifier: change = .noChange
            }
            for range in change.crossFieldKeys { owner.crossFieldKeys.set(range.key, count: range.count, value: fieldId) }
            result[key] = FieldChange(fieldKind: kind, change: change)
        }
        return result
    }
    private func encodeDetachedNodes(_ nodes: ChangeAtomIdBTree<any TreeChunk>?, context: ModularCodecContext) throws -> JSONValue? {
        guard let nodes else { return nil }
        var groups: [JSONValue] = []
        var batch: [any TreeChunk] = []
        var group: [JSONValue] = []
        var groupRevision: JSONValue?
        var hasGroup = false
        func flush() {
            guard hasGroup else { return }
            var tuple: [JSONValue] = [.array(group)]
            if let groupRevision { tuple.append(groupRevision) }
            groups.append(.array(tuple))
        }
        for (id, chunk) in nodes.entries {
            guard let chunk else { throw JSONDecodingError("missing build chunk") }
            let encodedRevision = try id.revision == context.revision ? nil : id.revision.map(revisions.encode)
            if !hasGroup || encodedRevision != groupRevision {
                flush()
                group = []
                groupRevision = encodedRevision
                hasGroup = true
            }
            group.append(.array([.number(id.localId), .number(Double(batch.count))]))
            batch.append(chunk)
        }
        flush()
        guard !groups.isEmpty else { return nil }
        guard let chunks else { throw JSONDecodingError("chunked-forest codec is required for detached nodes") }
        var result = JSObject<JSONValue>()
        result["builds"] = .array(groups)
        result["trees"] = try chunks.encode(batch, context: context)
        return .object(result)
    }
    private func decodeDetachedNodes(_ encoded: JSONValue, context: ModularCodecContext) throws -> ChangeAtomIdBTree<any TreeChunk>? {
        let groups = try encoded.member("builds").asArray()
        guard !groups.isEmpty else { return nil }
        guard let chunks else { throw JSONDecodingError("chunked-forest codec is required for detached nodes") }
        let batch = try chunks.decode(encoded.member("trees"), context: context)
        let nodes: ChangeAtomIdBTree<any TreeChunk> = newChangeAtomIdBTree(context: storageContext)
        for value in groups {
            let group = try value.asArray()
            guard group.count == 1 || group.count == 2 else { throw JSONDecodingError("invalid encoded build group") }
            let revision = try group.count == 2 ? revisions.decode(group[1], originatorId: context.originatorId) : context.revision
            for value in try group[0].asArray() {
                let pair = try value.asArray()
                guard pair.count == 2 else { throw JSONDecodingError("invalid encoded build pair") }
                let id = try atoms.decode(.number(try pair[0].asNumber()), revision: revision, originatorId: context.originatorId)
                let index = try pair[1].asInt()
                guard batch.indices.contains(index) else { throw JSONDecodingError("0x898: build chunk index out of bounds") }
                nodes.set(id, batch[index])
            }
        }
        return nodes
    }
    private func constraintJSON(_ violated: Bool) -> JSONValue {
        var object = JSObject<JSONValue>()
        object["violated"] = .bool(violated)
        return .object(object)
    }
    private func decodeConstraint(_ value: JSONValue) throws -> Bool {
        guard case .bool(let violated) = try value.member("violated") else { throw JSONDecodingError("invalid constraint violation flag") }
        return violated
    }
}
