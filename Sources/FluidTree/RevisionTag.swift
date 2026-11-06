import FluidJS
import FluidIdCompressor

/// core/rebase/types.ts: session-space compressed revision or the root sentinel.
public enum RevisionTag: Hashable, Sendable {
    case root
    case compressed(Double)
}

/// core/rebase/revisionTagCodec.ts.
public final class RevisionTagCodec {
    public let localSessionId: String
    private let idCompressor: IdCompressor

    public init(_ idCompressor: IdCompressor) {
        self.idCompressor = idCompressor
        localSessionId = idCompressor.localSessionId
    }

    public func encode(_ tag: RevisionTag) throws -> JSONValue {
        switch tag {
        case .root:
            return .string("root")
        case .compressed(let id):
            return .number(try idCompressor.normalizeToOpSpace(id))
        }
    }

    public func decode(_ encoded: JSONValue, originatorId: String) throws -> RevisionTag {
        if encoded == .string("root") {
            return .root
        }
        let id = try encoded.asNumber()
        guard id.isFinite, id.rounded(.towardZero) == id, abs(id) <= 9_007_199_254_740_991 else {
            throw JSONDecodingError("invalid compressed revision")
        }
        return .compressed(try idCompressor.normalizeToSessionSpace(id, originSessionId: originatorId))
    }
}
