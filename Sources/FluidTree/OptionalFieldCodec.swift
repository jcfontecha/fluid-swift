import FluidJS

/// feature-libraries/optional-field/optionalFieldCodecV2.ts. V2 is the only registered version.
public struct OptionalFieldCodec {
    private let atoms: ChangeAtomIdCodec
    public init(_ revisions: RevisionTagCodec) { atoms = ChangeAtomIdCodec(revisions) }

    public func encode(_ change: OptionalChangeset, revision: RevisionTag?, encodeNode: (ChangeAtomId) throws -> JSONValue) throws -> JSONValue {
        var result = JSObject<JSONValue>()
        if !change.moves.isEmpty {
            result["m"] = .array(try change.moves.map { .array([try atoms.encode($0.src, revision: revision), try atoms.encode($0.dst, revision: revision)]) })
        }
        if let replace = change.valueReplace {
            var value = JSObject<JSONValue>()
            value["e"] = .bool(replace.isEmpty)
            value["d"] = try atoms.encode(replace.dst, revision: revision)
            if let source = replace.src { value["s"] = try encodeRegister(source, revision: revision) }
            result["r"] = .object(value)
        }
        if !change.childChanges.isEmpty {
            result["c"] = .array(try change.childChanges.map { .array([try encodeRegister($0.register, revision: revision), try encodeNode($0.change)]) })
        }
        return .object(result)
    }
    public func decode(_ value: JSONValue, revision: RevisionTag?, originatorId: String, decodeNode: (JSONValue) throws -> ChangeAtomId) throws -> OptionalChangeset {
        let object = try value.asObject()
        var result = OptionalChangeset()
        if let moves = object["m"] {
            result.moves = try moves.asArray().map { value in
                let pair = try value.asArray()
                guard pair.count == 2 else { throw JSONDecodingError("expected optional move pair") }
                return OptionalMove(try atoms.decode(pair[0], revision: revision, originatorId: originatorId), try atoms.decode(pair[1], revision: revision, originatorId: originatorId))
            }
        }
        if let children = object["c"] {
            result.childChanges = try children.asArray().map { value in
                let pair = try value.asArray()
                guard pair.count == 2 else { throw JSONDecodingError("expected optional child pair") }
                return OptionalChildChange(try decodeRegister(pair[0], revision: revision, originatorId: originatorId), try decodeNode(pair[1]))
            }
        }
        if let replace = object["r"] {
            let fields = try replace.asObject()
            guard case .bool(let empty) = try replace.member("e") else { throw JSONDecodingError("expected optional isEmpty boolean") }
            let destination = try atoms.decode(replace.member("d"), revision: revision, originatorId: originatorId)
            let source = try fields["s"].map { try decodeRegister($0, revision: revision, originatorId: originatorId) }
            result.valueReplace = OptionalReplace(isEmpty: empty, src: source, dst: destination, sourceFirst: false)
        }
        return result
    }
    private func encodeRegister(_ id: RegisterId, revision: RevisionTag?) throws -> JSONValue {
        switch id {
        case .active: return .null
        case .detached(let atom): return try atoms.encode(atom, revision: revision)
        }
    }
    private func decodeRegister(_ value: JSONValue, revision: RevisionTag?, originatorId: String) throws -> RegisterId {
        value == .null ? .active : .detached(try atoms.decode(value, revision: revision, originatorId: originatorId))
    }
}
