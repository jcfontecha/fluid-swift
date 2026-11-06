import Foundation
import FluidJS
import FluidIdCompressor
import FluidTree

// T3 native peer: replays a harness/src/tree-editmanager scenario on Swift EditManagers and prints
// the same records world.ts produces. It receives only the scenario, never TS results.

private struct EditSpec {
    enum Kind: String { case insert, remove, move, crossMove, nested }
    let kind: Kind
    let field: JSString
    let index: Int
    let count: Int
    let destination: Int
    let metadata: Int
    init(_ value: JSONValue) throws {
        guard let kind = Kind(rawValue: try value.member("kind").asString().description) else {
            throw JSONDecodingError("unknown edit kind")
        }
        self.kind = kind
        field = try value.member("field").asString()
        index = try value.member("index").asInt()
        count = try value.member("count").asInt()
        destination = try value.member("destination").asInt()
        metadata = try value.member("metadata").asInt()
        guard field == "a" || field == "b" else {
            throw JSONDecodingError("invalid edit field")
        }
    }
}

private enum SummaryFormat {
    case v3, v4, v6, v7, shared
    static let all: [SummaryFormat] = [.v3, .v4, .v6, .v7, .shared]
    init(_ value: JSONValue) throws {
        switch value {
        case .number(3): self = .v3
        case .number(4): self = .v4
        case .number(6): self = .v6
        case .number(7): self = .v7
        case .string("shared"): self = .shared
        default: throw JSONDecodingError("unknown summary format \(value)")
        }
    }
    var label: String {
        switch self {
        case .v3: return "3"
        case .v4: return "4"
        case .v6: return "6"
        case .v7: return "7"
        case .shared: return "shared"
        }
    }
    var version: EditManagerFormatVersion {
        switch self {
        case .v3: return .v3
        case .v4: return .v4
        case .v6: return .v6
        case .v7: return .v7
        case .shared: return .vSharedBranches
        }
    }
    /// shared-tree/sharedTree.ts: v3 -> modular 3, v4 and vSharedBranches -> 4, v6/v7 -> 5.
    var changeFormat: Int {
        switch self {
        case .v3: return 3
        case .v4, .shared: return 4
        case .v6, .v7: return 5
        }
    }
}

private enum Action {
    case edit(peer: Int, edits: [EditSpec])
    case noop(peer: Int)
    case sequence(peer: Int)
    case deliver(peer: Int, split: Int)
    case retention(peer: Int, value: HistoryRetention)
    case fork(peer: Int)
    case rebaseFork(peer: Int, fork: Int)
    case disposeFork(peer: Int, fork: Int)
    case join(from: Int, format: SummaryFormat)
    case snapshot(peer: Int)

    init(_ value: JSONValue) throws {
        let type = try value.member("type").asString().description
        func int(_ key: JSString) throws -> Int { try value.member(key).asInt() }
        switch type {
        case "edit": self = .edit(peer: try int("peer"), edits: try value.member("edits").asArray().map(EditSpec.init))
        case "noop": self = .noop(peer: try int("peer"))
        case "sequence": self = .sequence(peer: try int("peer"))
        case "deliver": self = .deliver(peer: try int("peer"), split: try int("split"))
        case "retention":
            switch try value.member("value") {
            case .bool(let flag): self = .retention(peer: try int("peer"), value: .flag(flag))
            case .number: self = .retention(peer: try int("peer"), value: .commits(try value.member("value").asInt()))
            default: throw JSONDecodingError("invalid retention")
            }
        case "fork": self = .fork(peer: try int("peer"))
        case "rebaseFork": self = .rebaseFork(peer: try int("peer"), fork: try int("fork"))
        case "disposeFork": self = .disposeFork(peer: try int("peer"), fork: try int("fork"))
        case "join": self = .join(from: try int("from"), format: try SummaryFormat(try value.member("format")))
        case "snapshot": self = .snapshot(peer: try int("peer"))
        default: throw JSONDecodingError("unknown action \(type)")
        }
    }
}

private struct WireCommit {
    let revision: RevisionTag
    let bytes: String
    let metadata: Int
}

private enum Message {
    case op(refSeq: Int, commits: [WireCommit])
    case noop(refSeq: Int)
    var refSeq: Int {
        switch self {
        case .op(let refSeq, _), .noop(let refSeq): return refSeq
        }
    }
    var kind: String {
        switch self {
        case .op: return "op"
        case .noop: return "noop"
        }
    }
}

private struct Sequenced {
    let seq: Int
    let msn: Int
    let client: Int
    let message: Message
}

private final class Peer {
    let session: String
    let manager: EditManager<ModularChangeFamily>
    var forks: [SharedTreeBranch<ModularChangeFamily>?] = []
    var outbox: [Message] = []
    var processed = 0
    var lastSeq = 0
    init(session: String, manager: EditManager<ModularChangeFamily>) {
        self.session = session
        self.manager = manager
    }
}

private func sessionId(_ index: Int) -> String {
    let digits = String(index + 1)
    return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits
}

/// world.ts metadataTree: flat metadata, nested metadata with an array-index key, and a tree
/// without metadata.
private func metadataTree(_ variant: Int) throws -> CustomMetadataTree? {
    switch variant {
    case 0:
        return nil
    case 1:
        var metadata = JSObject<JSONValue>()
        metadata["label"] = .string("one")
        return CustomMetadataTree(metadata: metadata, children: [])
    case 2:
        var metadata = JSObject<JSONValue>()
        metadata["label"] = .string("two")
        metadata["1"] = .bool(true)
        return CustomMetadataTree(metadata: nil, children: [CustomMetadataTree(metadata: metadata, children: [])])
    case 3:
        return CustomMetadataTree(metadata: nil, children: [])
    default:
        throw JSONDecodingError("unknown metadata variant \(variant)")
    }
}

private final class World {
    let compressor: IdCompressor
    let family = ModularChangeFamily()
    let revisionTagCodec: RevisionTagCodec
    let changeCodec: ModularChangeCodec
    var peers: [Peer] = []
    var sequenced: [Sequenced] = []
    var clientRefSeq: [Int] = []
    var rows: [[String]] = []
    var seq = 0
    var msn = 0

    init(peerCount: Int) throws {
        compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        revisionTagCodec = RevisionTagCodec(compressor)
        changeCodec = try ModularChangeCodec(version: 5, revisionTagCodec: revisionTagCodec, storageContext: family.context)
        for _ in 0..<peerCount {
            _ = try addPeer()
        }
    }

    /// Every minted revision is finalized, so op-space revisions decode under any originator.
    func mint() throws -> RevisionTag {
        let revision = RevisionTag.compressed(try compressor.generateCompressedId())
        try compressor.finalizeCreationRange(compressor.takeNextCreationRange())
        return revision
    }

    func addPeer() throws -> Peer {
        let index = peers.count
        let manager = try EditManager(changeFamily: family, localSessionId: sessionId(index)) { [unowned self] in
            try self.mint()
        }
        let peer = Peer(session: sessionId(index), manager: manager)
        peers.append(peer)
        clientRefSeq.append(0)
        return peer
    }

    func peer(_ index: Int) throws -> Peer {
        guard peers.indices.contains(index) else {
            throw JSONDecodingError("missing peer \(index)")
        }
        return peers[index]
    }

    func summaryCodec(_ format: SummaryFormat) throws -> EditManagerCodec<ModularChangeCodec> {
        let changeCodec = try ModularChangeCodec(version: format.changeFormat, revisionTagCodec: revisionTagCodec, storageContext: family.context)
        return EditManagerCodec(version: format.version, changeCodec: changeCodec, revisionTagCodec: revisionTagCodec, idCompressor: compressor)
    }

    func encodeRevision(_ revision: RevisionTag) throws -> String {
        JSON.stringify(try revisionTagCodec.encode(revision))
    }

    func changeBytes(_ change: ModularChangeset, revision: RevisionTag) throws -> String {
        JSON.stringify(try changeCodec.encode(change, context: ModularCodecContext(revision: revision, originatorId: compressor.localSessionId)))
    }

    func decodeChange(_ bytes: String, revision: RevisionTag) throws -> ModularChangeset {
        try changeCodec.decode(try JSON.parse(bytes), context: ModularCodecContext(revision: revision, originatorId: compressor.localSessionId))
    }

    /// world.ts build, mirroring FluidTreePeer's construction of the same edits.
    func build(_ spec: EditSpec, revision: RevisionTag) throws -> ModularChangeset {
        let atom = ChangeAtomId(localId: 0, revision: revision)
        let attach = ChangeAtomId(localId: 8, revision: revision)
        let path = FieldUpPath(field: spec.field)
        let other = FieldUpPath(field: spec.field == "a" ? "b" : "a")
        let builder = family.buildEditor { _ in }
        _ = try builder.generateId(64)
        let seq = SequenceFieldEditor()
        func description(_ path: FieldUpPath, _ marks: [SequenceMark]) -> EditDescription {
            .field(path: path, change: FieldChange(fieldKind: .sequence, change: .sequence(marks)), revision: revision)
        }
        switch spec.kind {
        case .insert:
            return try builder.buildChanges([description(path, seq.insert(spec.index, count: spec.count, firstId: atom, revision: revision))])
        case .remove:
            return try builder.buildChanges([description(path, seq.remove(spec.index, count: spec.count, id: 0, revision: revision))])
        case .move:
            return try builder.buildChanges([description(path, seq.move(spec.index, count: spec.count, destination: spec.destination, detachCellId: 0, attachCellId: attach, revision: revision))])
        case .crossMove:
            return try builder.buildChanges([
                description(path, seq.moveOut(spec.index, count: spec.count, id: 0, revision: revision)),
                description(other, seq.moveIn(spec.destination, count: spec.count, moveId: 0, attachCellId: attach, revision: revision)),
            ])
        case .nested:
            let nested = FieldUpPath(parent: UpPath(parentField: spec.field, parentIndex: spec.index), field: "children")
            return try builder.buildChanges([description(nested, seq.insert(0, count: spec.count, firstId: atom, revision: revision))])
        }
    }

    func summarizable(_ index: Int) throws -> Bool {
        let manager = try peer(index).manager
        return try manager.getLocalBranch(.main).getHead() === manager.getTrunkHead(.main)
    }

    func execute(_ action: Action) throws {
        switch action {
        case .edit(let index, let specs):
            try edit(index, specs)
        case .noop(let index):
            let peer = try peer(index)
            peer.outbox.append(.noop(refSeq: peer.lastSeq))
        case .sequence(let index):
            try sequence(index)
        case .deliver(let index, let split):
            try deliver(index, split: split)
            try snapshot(index)
        case .retention(let index, let value):
            try peer(index).manager.setHistoryRetention(value)
            try snapshot(index)
        case .fork(let index):
            let peer = try peer(index)
            peer.forks.append(try peer.manager.getLocalBranch(.main).fork())
            try snapshot(index)
        case .rebaseFork(let index, let forkIndex):
            let peer = try peer(index)
            guard peer.forks.indices.contains(forkIndex), let fork = peer.forks[forkIndex] else {
                throw JSONDecodingError("missing fork")
            }
            try fork.rebaseOnto(try peer.manager.getLocalBranch(.main))
            try snapshot(index)
        case .disposeFork(let index, let forkIndex):
            let peer = try peer(index)
            guard peer.forks.indices.contains(forkIndex), let fork = peer.forks[forkIndex] else {
                throw JSONDecodingError("missing fork")
            }
            try fork.dispose()
            peer.forks[forkIndex] = nil
            try snapshot(index)
        case .join(let from, let format):
            try join(from: from, format: format)
        case .snapshot(let index):
            try snapshot(index)
        }
    }

    private func edit(_ index: Int, _ specs: [EditSpec]) throws {
        let peer = try peer(index)
        let branch = try peer.manager.getLocalBranch(.main)
        var commits: [WireCommit] = []
        for spec in specs {
            let revision = try mint()
            let change = try build(spec, revision: revision)
            try branch.apply(tagChange(change, revision), kind: .defaultKind, customMetadata: try metadataTree(spec.metadata))
            commits.append(WireCommit(revision: revision, bytes: try changeBytes(change, revision: revision), metadata: spec.metadata))
        }
        peer.outbox.append(.op(refSeq: peer.lastSeq, commits: commits))
        var row = ["wire", String(index), String(peer.lastSeq)]
        for commit in commits {
            row.append(try encodeRevision(commit.revision))
            row.append(commit.bytes)
        }
        rows.append(row)
        try snapshot(index)
    }

    private func sequence(_ index: Int) throws {
        let peer = try peer(index)
        guard !peer.outbox.isEmpty else {
            throw JSONDecodingError("empty outbox")
        }
        let message = peer.outbox.removeFirst()
        seq += 1
        clientRefSeq[index] = message.refSeq
        // The service's minimum sequence number never regresses.
        msn = max(msn, clientRefSeq.min() ?? 0)
        sequenced.append(Sequenced(seq: seq, msn: msn, client: index, message: message))
        rows.append(["seq", String(seq), String(msn), String(index), message.kind, String(message.refSeq)])
    }

    private func deliver(_ index: Int, split: Int) throws {
        let peer = try peer(index)
        guard sequenced.indices.contains(peer.processed) else {
            throw JSONDecodingError("nothing to deliver")
        }
        let delivered = sequenced[peer.processed]
        let manager = peer.manager
        if case .op(let refSeq, let wireCommits) = delivered.message {
            let commits = try wireCommits.map { commit in
                GraphCommit(revision: commit.revision, change: try decodeChange(commit.bytes, revision: commit.revision), parent: nil, customMetadata: try metadataTree(commit.metadata))
            }
            let session = try self.peer(delivered.client).session
            if split > 0 {
                try manager.addSequencedChanges(Array(commits[..<split]), sessionId: session, sequenceNumber: delivered.seq, referenceSequenceNumber: refSeq, branchId: .main)
                try manager.addSequencedChanges(Array(commits[split...]), sessionId: session, sequenceNumber: delivered.seq, referenceSequenceNumber: refSeq, branchId: .main)
            } else {
                try manager.addSequencedChanges(commits, sessionId: session, sequenceNumber: delivered.seq, referenceSequenceNumber: refSeq, branchId: .main)
            }
        }
        try manager.advanceMinimumSequenceNumber(delivered.msn)
        peer.processed += 1
        peer.lastSeq = delivered.seq
    }

    private func join(from: Int, format: SummaryFormat) throws {
        let source = try peer(from)
        let codec = try summaryCodec(format)
        let bytes = JSON.stringify(try codec.encode(try source.manager.getSummaryData(), isSummary: true))
        let peer = try addPeer()
        let index = peers.count - 1
        try peer.manager.loadSummaryData(try codec.decode(try JSON.parse(bytes), isSummary: true))
        peer.processed = source.processed
        peer.lastSeq = source.lastSeq
        clientRefSeq[index] = source.lastSeq
        rows.append(["join", String(index), String(from), format.label, bytes])
        try snapshot(index)
    }

    private func commitRow(_ commit: GraphCommit<ModularChangeset>) throws -> [String] {
        [try encodeRevision(commit.revision), try changeBytes(commit.change, revision: commit.revision)]
    }

    private func snapshot(_ index: Int) throws {
        let peer = try peer(index)
        let manager = peer.manager
        let latest = manager.getLatestSequenceNumber().map(String.init) ?? "undefined"
        rows.append(["peer", String(index), latest, String(manager.getLongestBranchLength())])
        rows.append(["trunk", String(index)] + (try manager.getTrunkCommits(.main).flatMap(commitRow)))
        let local = try manager.getLocalBranch(.main)
        rows.append(["local", String(index)] + (try commitRow(local.getHead())) + (try manager.getLocalCommits(.main).flatMap(commitRow)))
        for (forkIndex, fork) in peer.forks.enumerated() {
            if let fork {
                rows.append(["fork", String(index), String(forkIndex)] + (try commitRow(fork.getHead())))
            }
        }
        if try summarizable(index) {
            let data = try manager.getSummaryData()
            rows.append(["summary", String(index)] + (try SummaryFormat.all.map { format in
                JSON.stringify(try summaryCodec(format).encode(data, isSummary: true))
            }))
        }
    }
}

private func run(_ scenario: JSONValue) throws -> JSONValue {
    let world = try World(peerCount: try scenario.member("peers").asInt())
    for action in try scenario.member("actions").asArray() {
        try world.execute(try Action(action))
    }
    return .array(world.rows.map { row in .array(row.map { .string(JSString($0)) }) })
}

while let line = readLine() {
    do {
        let result = try run(JSON.parse(line))
        FileHandle.standardOutput.write(Data((JSON.stringify(result) + "\n").utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
