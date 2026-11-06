import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

/// Shared setup for the EditManager tests: one finalized ID space, as in harness/src/tree-editmanager.
private final class EditManagerFixture {
    let compressor: IdCompressor
    let family = ModularChangeFamily()
    let revisions: RevisionTagCodec
    let changeCodec: ModularChangeCodec

    init() throws {
        compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        revisions = RevisionTagCodec(compressor)
        changeCodec = try ModularChangeCodec(version: 5, revisionTagCodec: revisions, storageContext: family.context)
    }

    func mint() throws -> RevisionTag {
        let revision = RevisionTag.compressed(try compressor.generateCompressedId())
        try compressor.finalizeCreationRange(compressor.takeNextCreationRange())
        return revision
    }

    func manager(_ index: Int) throws -> EditManager<ModularChangeFamily> {
        try EditManager(changeFamily: family, localSessionId: session(index)) { [unowned self] in try self.mint() }
    }

    func session(_ index: Int) -> String {
        "00000000-0000-4000-8000-00000000000\(index + 1)"
    }

    /// world.ts build for insert, remove and nested edits.
    func build(_ kind: String, field: JSString, index: Int, count: Int, revision: RevisionTag) throws -> ModularChangeset {
        let builder = family.buildEditor { _ in }
        _ = try builder.generateId(64)
        let seq = SequenceFieldEditor()
        let atom = ChangeAtomId(localId: 0, revision: revision)
        func description(_ path: FieldUpPath, _ marks: [SequenceMark]) -> EditDescription {
            .field(path: path, change: FieldChange(fieldKind: .sequence, change: .sequence(marks)), revision: revision)
        }
        switch kind {
        case "insert":
            return try builder.buildChanges([description(FieldUpPath(field: field), seq.insert(index, count: count, firstId: atom, revision: revision))])
        case "remove":
            return try builder.buildChanges([description(FieldUpPath(field: field), seq.remove(index, count: count, id: 0, revision: revision))])
        default:
            let nested = FieldUpPath(parent: UpPath(parentField: field, parentIndex: index), field: "children")
            return try builder.buildChanges([description(nested, seq.insert(0, count: count, firstId: atom, revision: revision))])
        }
    }

    func commit(_ revision: RevisionTag, _ change: ModularChangeset, metadata: CustomMetadataTree? = nil) -> GraphCommit<ModularChangeset> {
        GraphCommit(revision: revision, change: change, parent: nil, customMetadata: metadata)
    }

    func summaries(_ manager: EditManager<ModularChangeFamily>) throws -> [String] {
        let data = try manager.getSummaryData()
        let formats: [(EditManagerFormatVersion, Int)] = [(.v3, 3), (.v4, 4), (.v6, 5), (.v7, 5), (.vSharedBranches, 4)]
        return try formats.map { version, changeFormat in
            JSON.stringify(try codec(version, changeFormat).encode(data, isSummary: true))
        }
    }

    func codec(_ version: EditManagerFormatVersion, _ changeFormat: Int) throws -> EditManagerCodec<ModularChangeCodec> {
        EditManagerCodec(version: version, changeCodec: try ModularChangeCodec(version: changeFormat, revisionTagCodec: revisions, storageContext: family.context), revisionTagCodec: revisions, idCompressor: compressor)
    }

    func commitRows(_ commits: [GraphCommit<ModularChangeset>]) throws -> [String] {
        try commits.flatMap { commit in
            [JSON.stringify(try revisions.encode(commit.revision)), JSON.stringify(try changeCodec.encode(commit.change, context: ModularCodecContext(revision: commit.revision, originatorId: compressor.localSessionId)))]
        }
    }
}

private func fixture() throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "edit-manager", withExtension: "json", subdirectory: "Fixtures"))
    return try JSON.parse(String(decoding: Data(contentsOf: url), as: UTF8.self))
}

private func strings(_ value: JSONValue) throws -> [String] {
    try value.asArray().map { try $0.asString().description }
}

@Suite struct EditManagerTests {
    /// Replays harness/src/tree-editmanager/fixtures.ts call for call and compares with the TS output.
    @Test func matchesTypeScriptFixture() throws {
        let expected = try fixture()
        let f = try EditManagerFixture()
        let observer = try f.manager(0)
        let local = try f.manager(1)
        let remote = f.session(2)
        var labelOne = JSObject<JSONValue>()
        labelOne["label"] = .string("one")
        var labelTwo = JSObject<JSONValue>()
        labelTwo["label"] = .string("two")
        labelTwo["1"] = .bool(true)

        let r1 = try f.mint()
        let c1 = f.commit(r1, try f.build("insert", field: "a", index: 0, count: 2, revision: r1), metadata: CustomMetadataTree(metadata: labelOne, children: []))
        try local.getLocalBranch(.main).apply(tagChange(c1.change, r1), kind: .defaultKind, customMetadata: c1.customMetadata)
        let r2 = try f.mint()
        let c2 = f.commit(r2, try f.build("insert", field: "a", index: 0, count: 1, revision: r2))
        let r3 = try f.mint()
        let c3 = f.commit(r3, try f.build("remove", field: "a", index: 0, count: 1, revision: r3), metadata: CustomMetadataTree(metadata: nil, children: [CustomMetadataTree(metadata: labelTwo, children: [])]))
        let r4 = try f.mint()
        let c4 = f.commit(r4, try f.build("insert", field: "b", index: 0, count: 1, revision: r4))
        let r5 = try f.mint()
        let c5 = try f.build("nested", field: "a", index: 1, count: 2, revision: r5)
        try local.getLocalBranch(.main).apply(tagChange(c5, r5), kind: .defaultKind, customMetadata: nil)

        for manager in [observer, local] {
            try manager.addSequencedChanges([c1], sessionId: f.session(1), sequenceNumber: 1, referenceSequenceNumber: 0, branchId: .main)
            try manager.addSequencedChanges([c2], sessionId: remote, sequenceNumber: 2, referenceSequenceNumber: 0, branchId: .main)
        }
        // A two-commit batch, delivered to the observer in two bunches.
        try observer.addSequencedChanges([c3], sessionId: remote, sequenceNumber: 3, referenceSequenceNumber: 2, branchId: .main)
        try observer.addSequencedChanges([c4], sessionId: remote, sequenceNumber: 3, referenceSequenceNumber: 2, branchId: .main)
        try local.addSequencedChanges([c3, c4], sessionId: remote, sequenceNumber: 3, referenceSequenceNumber: 2, branchId: .main)
        for manager in [observer, local] {
            try manager.advanceMinimumSequenceNumber(1)
        }

        let observerSummaries = try f.summaries(observer)
        #expect(observerSummaries == (try strings(expected.member("observerSummaries"))))
        #expect(try f.commitRows(local.getTrunkCommits(.main)) == (try strings(expected.member("localTrunk"))))
        #expect(try f.commitRows(local.getLocalCommits(.main)) == (try strings(expected.member("localCommits"))))
        #expect([observer.getLongestBranchLength(), local.getLongestBranchLength()] == (try expected.member("longestBranch").asArray().map { try $0.asInt() }))

        let loaded = try f.manager(3)
        try loaded.loadSummaryData(try f.codec(.v7, 5).decode(try JSON.parse(observerSummaries[3]), isSummary: true))
        #expect(try f.summaries(loaded)[4] == (try expected.member("reloaded").asString().description))
        try observer.advanceMinimumSequenceNumber(3)
        #expect(try f.summaries(observer)[3] == (try expected.member("trimmedSummary").asString().description))
    }

    @Test func sequenceIdOrdering() {
        let infinite = SequenceId(sequenceNumber: 4, indexInBatch: .infinity)
        #expect(sequenceIdComparator(SequenceId(sequenceNumber: 4), SequenceId(sequenceNumber: 4, indexInBatch: 0)) == 0)
        #expect(sequenceIdComparator(infinite, infinite) == 0)
        #expect(sequenceIdComparator(SequenceId(sequenceNumber: 4, indexInBatch: 9), infinite) < 0)
        #expect(sequenceIdComparator(infinite, SequenceId(sequenceNumber: 5)) < 0)
        #expect(getUpperBoundOfPreviousSequenceId(SequenceId(sequenceNumber: 2)) == SequenceId(sequenceNumber: 1, indexInBatch: .infinity))
        #expect(getUpperBoundOfPreviousSequenceId(SequenceId(sequenceNumber: 1, indexInBatch: 2)) == SequenceId(sequenceNumber: 1, indexInBatch: 1))
    }

    @Test func commonAncestorPaths() {
        let root = GraphCommit<Int>(revision: .root, change: 0, parent: nil, customMetadata: nil)
        let a1 = mintCommit(root, revision: .compressed(1), change: 1, customMetadata: nil)
        let a2 = mintCommit(a1, revision: .compressed(2), change: 2, customMetadata: nil)
        let b1 = mintCommit(a1, revision: .compressed(3), change: 3, customMetadata: nil)
        let b2 = mintCommit(b1, revision: .compressed(4), change: 4, customMetadata: nil)
        var pathA: [GraphCommit<Int>] = []
        var pathB: [GraphCommit<Int>] = []
        #expect(findCommonAncestor(a2, path: &pathA, b2, path: &pathB) === a1)
        #expect(pathA.map(\.change) == [2])
        #expect(pathB.map(\.change) == [3, 4])
        var path: [GraphCommit<Int>] = []
        #expect(findAncestor(b2, path: &path) === root)
        #expect(path.map(\.change) == [1, 3, 4])
        let unrelated = GraphCommit<Int>(revision: .compressed(9), change: 9, parent: nil, customMetadata: nil)
        var cleared: [GraphCommit<Int>] = []
        #expect(findCommonAncestor(b2, path: &cleared, unrelated) == nil)
        #expect(cleared.isEmpty)
    }

    /// core/rebase/utils.ts remarks: a source commit whose revision is already on the target cancels out.
    @Test func rebaseBranchCancelsSequencedCommits() throws {
        let f = try EditManagerFixture()
        let root = GraphCommit(revision: .root, change: try f.family.compose([]), parent: nil, customMetadata: nil)
        let rb = try f.mint()
        let rc = try f.mint()
        let rd = try f.mint()
        let b = mintCommit(root, revision: rb, change: try f.build("insert", field: "a", index: 0, count: 1, revision: rb), customMetadata: nil)
        let c = mintCommit(b, revision: rc, change: try f.build("insert", field: "a", index: 0, count: 1, revision: rc), customMetadata: nil)
        let bPrime = mintCommit(root, revision: rb, change: b.change, customMetadata: nil)
        let d = mintCommit(bPrime, revision: rd, change: try f.build("insert", field: "b", index: 0, count: 1, revision: rd), customMetadata: nil)
        let result = try rebaseBranch(mintRevisionTag: f.mint, changeFamily: f.family, sourceHead: d, targetCommit: c)
        #expect(result.commits.deletedSourceCommits.map(\.revision) == [rb, rd])
        #expect(result.commits.targetCommits.map(\.revision) == [rb, rc])
        #expect(result.commits.sourceCommits.map(\.revision) == [rd])
        #expect(result.newSourceHead.parent === c)
        #expect(result.telemetryProperties == RebaseStats(sourceBranchLength: 2, rebaseDistance: 2, countDropped: 1))
    }
}
