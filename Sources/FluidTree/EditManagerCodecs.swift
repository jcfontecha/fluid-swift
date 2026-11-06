import FluidJS
import FluidIdCompressor

/// core/change-family/changeFamily.ts: ChangeFamilyCodec, the change codec an EditManager codec
/// depends on. The ID compressor lives in the codec's revision tag codec; Swift change codecs take
/// no stored schema, so EditManagerEncodingContext's `schema` and `hasSchemaChange` are not threaded.
public protocol ChangeFamilyCodec {
    associatedtype Change
    func encode(_ change: Change, context: ModularCodecContext) throws -> JSONValue
    func decode(_ encoded: JSONValue, context: ModularCodecContext) throws -> Change
}

extension ModularChangeCodec: ChangeFamilyCodec {}

/// shared-tree-core/editManagerFormatCommons.ts: EditManagerFormatVersion (the supported members;
/// v1, v2 and v5 are discontinued).
public enum EditManagerFormatVersion: Equatable {
    case v3
    case v4
    case v6
    case v7
    case vSharedBranches

    var encoded: JSONValue {
        switch self {
        case .v3: return .number(3)
        case .v4: return .number(4)
        case .v6: return .number(6)
        case .v7: return .number(7)
        case .vSharedBranches: return .string("shared-branches|v0.2")
        }
    }
}

/// shared-tree-core/editManagerCodecsV1toV4.ts (makeV1toV4andV6CodecWithVersion) and
/// editManagerCodecsVSharedBranches.ts (makeSharedBranchesCodecWithVersion).
public struct EditManagerCodec<Codec: ChangeFamilyCodec> {
    public typealias Change = Codec.Change
    public let version: EditManagerFormatVersion
    private let changeCodec: Codec
    private let revisionTagCodec: RevisionTagCodec
    private let idCompressor: IdCompressor

    public init(version: EditManagerFormatVersion, changeCodec: Codec, revisionTagCodec: RevisionTagCodec, idCompressor: IdCompressor) {
        self.version = version
        self.changeCodec = changeCodec
        self.revisionTagCodec = revisionTagCodec
        self.idCompressor = idCompressor
    }

    public func encode(_ data: SummaryData<Change>, isSummary: Bool) throws -> JSONValue {
        switch version {
        case .v3, .v4, .v6, .v7:
            // editManagerCodecsV1toV4.ts: custom metadata is written from v7.
            let mainBranch = try encodeSharedBranch(data.main, isSummary: isSummary, originatorId: data.originator, includeCustomMetadata: version == .v7)
            var encoded = JSObject<JSONValue>()
            encoded["trunk"] = try mainBranch.member("trunk")
            encoded["branches"] = try mainBranch.member("peers")
            encoded["version"] = version.encoded
            return .object(encoded)
        case .vSharedBranches:
            let mainBranch = try encodeSharedBranch(data.main, isSummary: isSummary, originatorId: data.originator, includeCustomMetadata: true)
            guard let originator = data.originator else {
                preconditionFailure("0xca5: Cannot encode vSharedBranches summary without originator")
            }
            var json = JSObject<JSONValue>()
            json["main"] = mainBranch
            json["originator"] = .string(JSString(originator))
            json["version"] = version.encoded
            if let branches = data.branches, branches.count > 0 {
                json["branches"] = .array(try branches.entries.map { _, branch in
                    try encodeSharedBranch(branch, isSummary: isSummary, originatorId: data.originator, includeCustomMetadata: true)
                })
            }
            return .object(json)
        }
    }

    public func decode(_ json: JSONValue, isSummary: Bool) throws -> SummaryData<Change> {
        switch version {
        case .v3, .v4, .v6, .v7:
            var branch = JSObject<JSONValue>()
            branch["trunk"] = try json.member("trunk")
            branch["peers"] = try json.member("branches")
            // Non "vSharedBranches" versions do not encode the summary originatorId.
            return SummaryData(originator: nil, main: try decodeSharedBranch(.object(branch), isSummary: isSummary, originatorId: nil), branches: nil)
        case .vSharedBranches:
            let originator = try json.member("originator").asString().description
            let mainBranch = try decodeSharedBranch(try json.member("main"), isSummary: isSummary, originatorId: originator)
            var decoded = SummaryData<Change>(originator: originator, main: mainBranch, branches: nil)
            if let encodedBranches = try json.asObject()["branches"] {
                var branches = OrderedMap<BranchId, SharedBranchSummaryData<Change>>()
                for encodedBranch in try encodedBranches.asArray() {
                    let decodedBranch = try decodeSharedBranch(encodedBranch, isSummary: isSummary, originatorId: originator)
                    guard let id = decodedBranch.id else {
                        throw JSONDecodingError("0xc66: Shared branches must have an id")
                    }
                    guard branches[id] == nil else {
                        throw JSONDecodingError("0xc67: Duplicate shared branch id")
                    }
                    branches[id] = decodedBranch
                }
                decoded.branches = branches
            }
            return decoded
        }
    }

    /// editManagerCodecsCommons.ts: encodeCommit. The commit's session is the originator.
    private func encodeCommit(revision: RevisionTag, change: Change, sessionId: String, customMetadata: CustomMetadataTree?, isSummary: Bool, includeCustomMetadata: Bool) throws -> JSObject<JSONValue> {
        var encoded = JSObject<JSONValue>()
        encoded["change"] = try changeCodec.encode(change, context: ModularCodecContext(revision: revision, originatorId: sessionId, isSummary: isSummary))
        encoded["revision"] = try revisionTagCodec.encode(revision)
        encoded["sessionId"] = .string(JSString(sessionId))
        if includeCustomMetadata, let customMetadata {
            encoded["customMetadata"] = encodeCustomMetadataTree(customMetadata)
        }
        return encoded
    }

    /// editManagerCodecsCommons.ts: decodeCommit.
    private func decodeCommit(_ commit: JSONValue, isSummary: Bool) throws -> Commit<Change> {
        let sessionId = try commit.member("sessionId").asString().description
        let revision = try revisionTagCodec.decode(try commit.member("revision"), originatorId: sessionId)
        return Commit(
            revision: revision,
            change: try changeCodec.decode(try commit.member("change"), context: ModularCodecContext(revision: revision, originatorId: sessionId, isSummary: isSummary)),
            sessionId: sessionId,
            customMetadata: try decodeCustomMetadataTree(try commit.asObject()["customMetadata"])
        )
    }

    /// editManagerCodecsCommons.ts: encodeSharedBranch.
    private func encodeSharedBranch(_ data: SharedBranchSummaryData<Change>, isSummary: Bool, originatorId: String?, includeCustomMetadata: Bool) throws -> JSONValue {
        var json = JSObject<JSONValue>()
        json["trunk"] = .array(try data.trunk.map { commit in
            var encoded = try encodeCommit(revision: commit.revision, change: commit.change, sessionId: commit.sessionId, customMetadata: commit.customMetadata, isSummary: isSummary, includeCustomMetadata: includeCustomMetadata)
            // copyPropertyIfDefined
            encoded["sequenceNumber"] = .number(Double(commit.sequenceNumber))
            if let indexInBatch = commit.indexInBatch {
                encoded["indexInBatch"] = .number(indexInBatch)
            }
            return .object(encoded)
        })
        json["peers"] = .array(try data.peerLocalBranches.entries.map { sessionId, branch in
            var encodedBranch = JSObject<JSONValue>()
            encodedBranch["base"] = try revisionTagCodec.encode(branch.base)
            encodedBranch["commits"] = .array(try branch.commits.map { commit in
                .object(try encodeCommit(revision: commit.revision, change: commit.change, sessionId: commit.sessionId, customMetadata: commit.customMetadata, isSummary: isSummary, includeCustomMetadata: includeCustomMetadata))
            })
            return .array([.string(JSString(sessionId)), .object(encodedBranch)])
        })
        if let session = data.session {
            json["session"] = .string(JSString(session))
        }
        // encodeBranchId yields undefined for "main", which JSON.stringify omits.
        if let id = data.id, case .compressed(let compressed) = id {
            json["id"] = .number(try idCompressor.normalizeToOpSpace(compressed))
        }
        if let name = data.name {
            json["name"] = .string(JSString(name))
        }
        if let author = data.author {
            json["author"] = .string(JSString(author))
        }
        if let base = data.base {
            precondition(originatorId != nil, "0xc62: Cannot encode branch base without originatorId")
            json["base"] = try revisionTagCodec.encode(base)
        }
        return .object(json)
    }

    /// editManagerCodecsCommons.ts: decodeSharedBranch.
    private func decodeSharedBranch(_ json: JSONValue, isSummary: Bool, originatorId: String?) throws -> SharedBranchSummaryData<Change> {
        let trunk = try json.member("trunk").asArray().map { encoded in
            let commit = try decodeCommit(encoded, isSummary: isSummary)
            let indexInBatch = try encoded.asObject()["indexInBatch"].map { try $0.asNumber() }
            return SequencedCommit(
                revision: commit.revision,
                change: commit.change,
                sessionId: commit.sessionId,
                customMetadata: commit.customMetadata,
                sequenceNumber: try encoded.member("sequenceNumber").asInt(),
                indexInBatch: indexInBatch
            )
        }
        var peerLocalBranches = OrderedMap<String, SummarySessionBranch<Change>>()
        for peer in try json.member("peers").asArray() {
            let tuple = try peer.asArray()
            guard tuple.count == 2 else {
                throw JSONDecodingError("expected [sessionId, branch] peer tuple")
            }
            let sessionId = try tuple[0].asString().description
            let branch = tuple[1]
            peerLocalBranches[sessionId] = SummarySessionBranch(
                base: try revisionTagCodec.decode(try branch.member("base"), originatorId: sessionId),
                commits: try branch.member("commits").asArray().map { try decodeCommit($0, isSummary: isSummary) }
            )
        }
        var data = SharedBranchSummaryData<Change>(id: nil, name: nil, session: nil, author: nil, base: nil, trunk: trunk, peerLocalBranches: peerLocalBranches)
        let object = try json.asObject()
        if let session = object["session"] {
            data.session = try session.asString().description
        }
        if let name = object["name"] {
            data.name = try name.asString().description
        }
        if let author = object["author"] {
            data.author = try author.asString().description
        }
        if let id = object["id"] {
            guard let originatorId else {
                throw JSONDecodingError("0xc63: Cannot decode branch id without originatorId")
            }
            data.id = .compressed(try idCompressor.normalizeToSessionSpace(try id.asNumber(), originSessionId: originatorId))
        }
        if let base = object["base"] {
            guard let originatorId else {
                throw JSONDecodingError("0xc64: Cannot decode branch base without originatorId")
            }
            data.base = try revisionTagCodec.decode(base, originatorId: originatorId)
        }
        return data
    }
}

/// shared-tree-core/customMetadataCodec.ts: encodeCustomMetadataTree (`{ m?, c? }`).
func encodeCustomMetadataTree(_ tree: CustomMetadataTree) -> JSONValue {
    var encoded = JSObject<JSONValue>()
    if let metadata = tree.metadata {
        encoded["m"] = .object(metadata)
    }
    if !tree.children.isEmpty {
        encoded["c"] = .array(tree.children.map(encodeCustomMetadataTree))
    }
    return .object(encoded)
}

/// shared-tree-core/customMetadataCodec.ts: decodeCustomMetadataTree. A tree in which no node
/// supplied metadata carries no information and decodes to nil.
func decodeCustomMetadataTree(_ encoded: JSONValue?) throws -> CustomMetadataTree? {
    guard let encoded else {
        return nil
    }
    let decoded = try decodeCustomMetadataNode(encoded)
    return hasMetadata(decoded) ? decoded : nil
}

private func decodeCustomMetadataNode(_ encoded: JSONValue) throws -> CustomMetadataTree {
    let object = try encoded.asObject()
    return CustomMetadataTree(
        metadata: try object["m"].map { try $0.asObject() },
        children: try object["c"].map { try $0.asArray().map(decodeCustomMetadataNode) } ?? []
    )
}

private func hasMetadata(_ node: CustomMetadataTree) -> Bool {
    node.metadata != nil || node.children.contains(where: hasMetadata)
}
