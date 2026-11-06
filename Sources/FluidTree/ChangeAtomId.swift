import FluidJS

/// core/rebase/types.ts: revision-scoped changeset-local identity.
public struct ChangeAtomId: Equatable, Hashable, Sendable {
    public var revision: RevisionTag?
    public var localId: Double

    public init(localId: Double, revision: RevisionTag? = nil) {
        self.localId = localId
        self.revision = revision
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
        return ChangeAtomId(localId: try decodeLocalId(encoded), revision: revision)
    }

    private func decodeLocalId(_ value: JSONValue) throws -> Double {
        let id = try value.asNumber()
        guard id.isFinite, id.rounded(.towardZero) == id, abs(id) <= 9_007_199_254_740_991 else {
            throw JSONDecodingError("invalid changeset local ID")
        }
        return id
    }
}
