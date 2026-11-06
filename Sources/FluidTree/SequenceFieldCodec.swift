import FluidJS

/// feature-libraries/sequence-field/sequenceFieldCodecV2.ts and sequenceFieldCodecV3.ts.
/// Node payloads belong to ModularChangeFamily and are encoded through callbacks.
public struct SequenceFieldCodec {
    public let version: Int
    private let revisions: RevisionTagCodec
    private let atoms: ChangeAtomIdCodec

    public init(version: Int, revisionTagCodec: RevisionTagCodec) throws {
        guard version == 2 || version == 3 else {
            throw JSONDecodingError("unsupported sequence codec version")
        }
        self.version = version
        revisions = revisionTagCodec
        atoms = ChangeAtomIdCodec(revisionTagCodec)
    }

    public func encode(_ marks: [SequenceMark], revision: RevisionTag?, encodeNode: (ChangeAtomId) throws -> JSONValue) throws -> JSONValue {
        .array(try marks.map { mark in
            var encoded = JSObject<JSONValue>()
            encoded["count"] = .number(Double(mark.count))
            if mark.effect != .noop {
                encoded["effect"] = try encodeEffect(mark.effect, revision: revision)
            }
            if let cell = mark.cellId {
                encoded["cellId"] = try atoms.encode(cell, revision: revision)
            }
            if let changes = mark.changes {
                encoded["changes"] = try encodeNode(changes)
            }
            return .object(encoded)
        })
    }

    public func decode(_ value: JSONValue, revision: RevisionTag?, originatorId: String, decodeNode: (JSONValue) throws -> ChangeAtomId) throws -> [SequenceMark] {
        try value.asArray().map { value in
            let object = try value.asObject()
            let count = try value.member("count").asInt()
            guard count >= 0 else {
                throw JSONDecodingError("negative sequence mark count")
            }
            var mark = SequenceMark(count: count)
            if let effect = object["effect"] {
                mark.effect = try decodeEffect(effect, revision: revision, originatorId: originatorId)
            }
            if let cell = object["cellId"] {
                mark.cellId = try atoms.decode(cell, revision: revision, originatorId: originatorId)
                // V2 legacy insert+detach and move+move represent cell renames.
                if version == 2, case .attachAndDetach(let attach, let detach) = mark.effect.kind {
                    mark = normalizeCellRename(cellId: try atoms.decode(cell, revision: revision, originatorId: originatorId), count: count, attach: attach, detach: detach)
                }
            }
            if let changes = object["changes"] {
                mark.changes = try decodeNode(changes)
            }
            return mark
        }
    }

    private func encodeEffect(_ effect: SequenceMarkEffect, revision: RevisionTag?) throws -> JSONValue {
        var payload = JSObject<JSONValue>()
        let name: JSString
        let id: Double
        let ownRevision: RevisionTag?
        let endpoint: ChangeAtomId?
        let override: ChangeAtomId?
        switch effect.kind {
        case .noop:
            throw JSONDecodingError("0xb2c: noop effect cannot be encoded")
        case .rename(let target):
            if version == 2 {
                return try encodeEffect(.attachAndDetach(
                    attach: .moveIn(id: -1, revision: nil, finalEndpoint: nil),
                    detach: .moveOut(id: -1, revision: nil, finalEndpoint: nil, idOverride: target)), revision: revision)
            }
            payload["idOverride"] = try atoms.encode(target, revision: revision)
            var encoded = JSObject<JSONValue>()
            encoded["rename"] = .object(payload)
            return .object(encoded)
        case .attachAndDetach(let attach, let detach):
            try validatePair(attach, detach)
            payload["attach"] = try encodeEffect(attach, revision: revision)
            payload["detach"] = try encodeEffect(detach, revision: revision)
            var encoded = JSObject<JSONValue>()
            encoded["attachAndDetach"] = .object(payload)
            return .object(encoded)
        case .insert(let value, let tag):
            (name, id, ownRevision, endpoint, override) = ("insert", value, tag, nil, nil)
        case .remove(let value, let tag, let target):
            (name, id, ownRevision, endpoint, override) = ("remove", value, tag, nil, target)
        case .moveIn(let value, let tag, let final):
            (name, id, ownRevision, endpoint, override) = ("moveIn", value, tag, final, nil)
        case .moveOut(let value, let tag, let final, let target):
            (name, id, ownRevision, endpoint, override) = ("moveOut", value, tag, final, target)
        }
        if let ownRevision, ownRevision != revision {
            payload["revision"] = try revisions.encode(ownRevision)
        }
        if let endpoint {
            payload["finalEndpoint"] = try atoms.encode(endpoint, revision: revision)
        }
        if let override {
            payload["idOverride"] = try atoms.encode(override, revision: revision)
        }
        payload["id"] = .number(id)
        var encoded = JSObject<JSONValue>()
        encoded[name] = .object(payload)
        return .object(encoded)
    }

    private func decodeEffect(_ value: JSONValue, revision: RevisionTag?, originatorId: String) throws -> SequenceMarkEffect {
        let object = try value.asObject()
        guard object.count == 1, let name = object.keys.first, let payload = object[name] else {
            throw JSONDecodingError("expected one sequence effect discriminator")
        }
        if name == "rename" && version == 3 {
            return .rename(idOverride: try atoms.decode(payload.member("idOverride"), revision: revision, originatorId: originatorId))
        }
        if name == "attachAndDetach" {
            let attach = try decodeEffect(payload.member("attach"), revision: revision, originatorId: originatorId)
            let detach = try decodeEffect(payload.member("detach"), revision: revision, originatorId: originatorId)
            try validatePair(attach, detach)
            if case .moveIn(let id, _, _) = attach.kind, id == -1 {
                let target: ChangeAtomId?
                switch detach.kind {
                case .remove(_, _, let override), .moveOut(_, _, _, let override): target = override
                default: target = nil
                }
                guard let target else {
                    throw JSONDecodingError("0x9f8: rename must have idOverride")
                }
                return .rename(idOverride: target)
            }
            return .attachAndDetach(attach: attach, detach: detach)
        }
        let fields = try payload.asObject()
        let id = try atoms.decode(.number(try payload.member("id").asNumber()), revision: nil, originatorId: originatorId).localId
        let tag: RevisionTag
        if let encodedRevision = fields["revision"] {
            tag = try revisions.decode(encodedRevision, originatorId: originatorId)
        } else if let revision {
            tag = revision
        } else {
            throw JSONDecodingError("0x996: implicit revision should be provided")
        }
        let endpoint = try fields["finalEndpoint"].map { try atoms.decode($0, revision: revision, originatorId: originatorId) }
        let override = try fields["idOverride"].map { try atoms.decode($0, revision: revision, originatorId: originatorId) }
        switch name {
        case "insert": return .insert(id: id, revision: tag)
        case "remove": return .remove(id: id, revision: tag, idOverride: override)
        case "moveIn": return .moveIn(id: id, revision: tag, finalEndpoint: endpoint)
        case "moveOut": return .moveOut(id: id, revision: tag, finalEndpoint: endpoint, idOverride: override)
        default: throw JSONDecodingError("unknown sequence effect discriminator")
        }
    }

    private func validatePair(_ attach: SequenceMarkEffect, _ detach: SequenceMarkEffect) throws {
        switch attach.kind {
        case .insert, .moveIn: break
        default: throw JSONDecodingError("invalid attach effect")
        }
        switch detach.kind {
        case .remove, .moveOut: break
        default: throw JSONDecodingError("invalid detach effect")
        }
    }
}
