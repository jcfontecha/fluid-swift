import FluidJS

/// core/rebase/types.ts: revision-scoped changeset-local identity.
public struct ChangeAtomId: Equatable, Hashable, Sendable {
    public enum PropertyOrder: Sendable { case localIdFirst, revisionFirst }
    public var revision: RevisionTag?
    public var localId: Double
    public var propertyOrder: PropertyOrder
    public var includesRevision: Bool

    public init(localId: Double, revision: RevisionTag? = nil, propertyOrder: PropertyOrder = .localIdFirst, includesRevision: Bool? = nil) {
        self.localId = localId
        self.revision = revision
        self.propertyOrder = propertyOrder
        self.includesRevision = includesRevision ?? (revision != nil)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.localId == rhs.localId && lhs.revision == rhs.revision }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(localId)
        hasher.combine(revision)
    }
    func fromTuple() -> Self {
        Self(localId: localId, revision: revision, propertyOrder: .revisionFirst, includesRevision: true)
    }
}

/// feature-libraries/changeAtomIdCodec.ts.
public struct ChangeAtomIdCodec {
    private let revisionTagCodec: RevisionTagCodec

    public init(_ revisionTagCodec: RevisionTagCodec) {
        self.revisionTagCodec = revisionTagCodec
    }

    public func encode(_ id: ChangeAtomId, revision: RevisionTag?) throws -> JSONValue {
        guard let ownRevision = id.revision, ownRevision != revision else {
            return .number(id.localId)
        }
        return .array([.number(id.localId), try revisionTagCodec.encode(ownRevision)])
    }

    public func decode(_ encoded: JSONValue, revision: RevisionTag?, originatorId: String) throws -> ChangeAtomId {
        if case .array(let tuple) = encoded {
            guard tuple.count == 2 else {
                throw JSONDecodingError("expected [localId, revision]")
            }
            return ChangeAtomId(
                localId: try decodeLocalId(tuple[0]),
                revision: try revisionTagCodec.decode(tuple[1], originatorId: originatorId))
        }
        return ChangeAtomId(localId: try decodeLocalId(encoded), revision: revision, includesRevision: true)
    }

    private func decodeLocalId(_ value: JSONValue) throws -> Double {
        let id = try value.asNumber()
        guard id.isFinite, id.rounded(.towardZero) == id, abs(id) <= 9_007_199_254_740_991 else {
            throw JSONDecodingError("invalid changeset local ID")
        }
        return id
    }
}
