import FluidJS

/// shared-tree-core/editManager.ts: minimumPossibleSequenceNumber (`Number.MIN_SAFE_INTEGER`).
public let minimumPossibleSequenceNumber = -9_007_199_254_740_991
private let minimumPossibleSequenceId = SequenceId(sequenceNumber: minimumPossibleSequenceNumber)

/// editManager.ts: rootRevision, the revision of the initial trunk base. Peer branches based on the
/// trunk base are always summarized with this tag.
private let rootRevision = RevisionTag.root

/// editManager.ts: the local history retention policy (`boolean | number`).
public enum HistoryRetention: Equatable {
    /// `true` retains all available history; `false` disables extra retention.
    case flag(Bool)
    /// Retains the newest given number of sequenced main-branch commits; 0 disables extra retention.
    case commits(Int)
}

/// shared-tree-core/editManagerFormatCommons.ts: Commit.
public struct Commit<Change> {
    public var revision: RevisionTag
    public var change: Change
    public var sessionId: String
    public var customMetadata: CustomMetadataTree?
    public init(revision: RevisionTag, change: Change, sessionId: String, customMetadata: CustomMetadataTree?) {
        self.revision = revision
        self.change = change
        self.sessionId = sessionId
        self.customMetadata = customMetadata
    }
}

/// shared-tree-core/editManagerFormatCommons.ts: SequencedCommit (a Commit and its SequenceId).
public struct SequencedCommit<Change> {
    public var revision: RevisionTag
    public var change: Change
    public var sessionId: String
    public var customMetadata: CustomMetadataTree?
    public var sequenceNumber: Int
    public var indexInBatch: Double?
    public init(revision: RevisionTag, change: Change, sessionId: String, customMetadata: CustomMetadataTree?, sequenceNumber: Int, indexInBatch: Double?) {
        self.revision = revision
        self.change = change
        self.sessionId = sessionId
        self.customMetadata = customMetadata
        self.sequenceNumber = sequenceNumber
        self.indexInBatch = indexInBatch
    }
}

/// shared-tree-core/editManagerFormatCommons.ts: SummarySessionBranch.
public struct SummarySessionBranch<Change> {
    public var base: RevisionTag
    public var commits: [Commit<Change>]
}

/// editManager.ts: SharedBranchSummaryData.
public struct SharedBranchSummaryData<Change> {
    public var id: BranchId?
    public var name: String?
    public var session: String?
    public var author: String?
    public var base: RevisionTag?
    public var trunk: [SequencedCommit<Change>]
    public var peerLocalBranches: OrderedMap<String, SummarySessionBranch<Change>>
}

/// editManager.ts: SummaryData, the in-memory data that summaries contain.
public struct SummaryData<Change> {
    public var originator: String?
    public var main: SharedBranchSummaryData<Change>
    public var branches: OrderedMap<BranchId, SharedBranchSummaryData<Change>>?
}

/// A JS `Set` of branches: insertion-ordered, compared by identity.
final class BranchSet<Family: ChangeFamily> {
    private(set) var branches: [SharedTreeBranch<Family>] = []
    var count: Int { branches.count }
    func has(_ branch: SharedTreeBranch<Family>) -> Bool {
        branches.contains { $0 === branch }
    }
    func add(_ branch: SharedTreeBranch<Family>) {
        if !has(branch) {
            branches.append(branch)
        }
    }
    func delete(_ branch: SharedTreeBranch<Family>) -> Bool {
        guard let index = branches.firstIndex(where: { $0 === branch }) else {
            return false
        }
        branches.remove(at: index)
        return true
    }
}

/// shared-tree-core/editManager.ts: EditManager.
/// Represents a local branch of a document and interprets the effect on the document of adding
/// sequenced changes, which were based on a given session's branch, to the document history.
/// (TS's optional telemetry logger, which only batches rebase statistics, is not ported.)
public final class EditManager<Family: ChangeFamily> {
    public typealias Change = Family.Rebaser.Change

    private let trimmer = Emitter<[RevisionTag]>()
    private let trimState = BranchTrimState()

    private var sharedBranches = OrderedMap<BranchId, SharedBranch<Family>>()

    /// Where on the main trunk every registered branch is based: each key is the sequence id of a
    /// trunk commit, the value every branch whose common ancestor with the trunk is that commit.
    /// This does not include the local branch.
    private let trunkBranches = BTree<SequenceId, BranchSet<Family>>(compare: sequenceIdComparator)

    /// The sequence number of the newest trunk commit received by all peers.
    private var minimumSequenceNumber = minimumPossibleSequenceNumber

    private var historyRetention = HistoryRetention.flag(false)

    /// The tail of the trunk, not part of the trunk itself. Each eviction makes the most recent
    /// evicted commit the new trunk base.
    private var trunkBase: GraphCommit<Change>

    public let changeFamily: Family
    public let localSessionId: String
    private let mintRevisionTag: () throws -> RevisionTag
    private let onSharedBranchCreated: ((BranchId) -> Void)?

    public init(changeFamily: Family, localSessionId: String, mintRevisionTag: @escaping () throws -> RevisionTag, onSharedBranchCreated: ((BranchId) -> Void)? = nil) throws {
        self.changeFamily = changeFamily
        self.localSessionId = localSessionId
        self.mintRevisionTag = mintRevisionTag
        self.onSharedBranchCreated = onSharedBranchCreated
        trunkBase = GraphCommit(revision: rootRevision, change: try changeFamily.rebaser.compose([]), parent: nil, customMetadata: nil)
        trunkBase.wasTrimmed = true

        let mainTrunk = SharedTreeBranch(head: trunkBase, changeFamily: changeFamily, mintRevisionTag: mintRevisionTag, trimState: trimState)
        mainTrunk.setTrimmer(trimmer)

        try createAndAddSharedBranch(.main, branchName: "main", sessionId: nil, parent: nil, branch: mainTrunk)
    }

    public func getHistoryRetention() -> HistoryRetention {
        historyRetention
    }

    /// Replaces the local retention policy for sequenced main-branch commits and trims immediately.
    public func setHistoryRetention(_ value: HistoryRetention) throws {
        if case .commits(let count) = value {
            precondition(count >= 0 && count <= 9_007_199_254_740_991, "0xd79: historyRetention must be a boolean or a nonnegative safe integer")
        }
        historyRetention = value
        try trimHistory()
    }

    /// An inclusive upper bound for commits removed by trimming under the retention policy.
    private func getUpperTrimmingBoundForHistory() throws -> SequenceId {
        if historyRetention == .flag(true) {
            return minimumPossibleSequenceId
        }
        let sequenceIdToCommit = try getSharedBranch(.main).sequenceIdToCommit
        if historyRetention == .flag(false) || historyRetention == .commits(0) {
            return sequenceIdToCommit.maxKey() ?? minimumPossibleSequenceId
        }
        // The map includes the trimmed base, which does not count toward retention.
        if case .commits(let retention) = historyRetention, retention < sequenceIdToCommit.count - 1 {
            var remaining = retention
            for (sequenceId, _) in sequenceIdToCommit.entries.reversed() {
                remaining -= 1
                if remaining == 0 {
                    return getUpperBoundOfPreviousSequenceId(sequenceId)
                }
            }
        }
        return minimumPossibleSequenceId
    }

    /// An inclusive upper bound for commits removed by trimming based on local forks.
    private func getUpperTrimmingBoundForLocalForks() throws -> SequenceId {
        guard let minimumBranchBaseSequenceId = trunkBranches.minKey() else {
            return try getSharedBranch(.main).sequenceIdToCommit.maxKey() ?? minimumPossibleSequenceId
        }
        return getUpperBoundOfPreviousSequenceId(minimumBranchBaseSequenceId)
    }

    /// An inclusive upper bound for commits removed by trimming based on the minimum sequence number.
    private func getUpperTrimmingBoundForMinimumSequenceNumber() -> SequenceId {
        SequenceId(sequenceNumber: minimumSequenceNumber, indexInBatch: .infinity)
    }

    public func getLocalBranch(_ branchId: BranchId) throws -> SharedTreeBranch<Family> {
        try getSharedBranch(branchId).localBranch
    }

    public func getSharedBranchName(_ branchId: BranchId) throws -> String? {
        try getSharedBranch(branchId).branchName
    }

    private func getSharedBranch(_ branchId: BranchId) throws -> SharedBranch<Family> {
        guard let branch = sharedBranches[branchId] else {
            throw JSONDecodingError("UsageError: No shared branch with such ID")
        }
        return branch
    }

    /// Makes `branch` known so it stays usable as the minimum sequence number advances.
    private func registerBranch(_ branch: SharedTreeBranch<Family>) throws {
        try trackBranch(branch)
        // Whenever the branch is rebased, update our record of its base trunk commit
        let offBeforeRebase = branch.events.beforeChange.on { [unowned self] change in
            if change.type == .rebase {
                try self.untrackBranch(branch)
            }
        }
        let offAfterRebase = branch.events.afterChange.on { [unowned self] change in
            if change.type == .rebase {
                try self.trackBranch(branch)
                try self.trimHistory()
            }
        }
        // When the branch is disposed, update our branch set and trim the trunk
        let offDispose = ListenerRemovals()
        offDispose.all.append(branch.events.dispose.on { [unowned self] in
            try self.untrackBranch(branch)
            try self.trimHistory()
            offBeforeRebase()
            offAfterRebase()
            for off in offDispose.all {
                off()
            }
        })
    }

    private func trackBranch(_ branch: SharedTreeBranch<Family>) throws {
        let main = try getSharedBranch(.main)
        guard let trunkCommit = findCommonAncestor(main.trunk.getHead(), branch.getHead()) else {
            preconditionFailure("0xad2: Expected branch to be related to main")
        }
        let sequenceId = main.getCommitSequenceId(trunkCommit.revision)
        let branches = getOrCreateTrunkBranches(sequenceId)

        precondition(!branches.has(branch), "0x670: Branch was registered more than once")
        branches.add(branch)
    }

    private func untrackBranch(_ branch: SharedTreeBranch<Family>) throws {
        let main = try getSharedBranch(.main)
        guard let trunkCommit = findCommonAncestor(main.trunk.getHead(), branch.getHead()) else {
            preconditionFailure("0xad3: Expected branch to be related to main")
        }
        let sequenceId = main.getCommitSequenceId(trunkCommit.revision)
        guard let branches = trunkBranches.get(sequenceId) else {
            preconditionFailure("0xad4: Expected branch to be tracked")
        }

        precondition(branches.delete(branch), "0x671: Expected branch to be tracked")
        if branches.count == 0 {
            trunkBranches.delete(sequenceId)
        }
    }

    private func getOrCreateTrunkBranches(_ sequenceId: SequenceId) -> BranchSet<Family> {
        if let branches = trunkBranches.get(sequenceId) {
            return branches
        }
        let branches = BranchSet<Family>()
        trunkBranches.set(sequenceId, branches)
        return branches
    }

    /// The sequence number of the latest sequenced change.
    public func getLatestSequenceNumber() -> Int? {
        var maxSequenceNumber: Int?
        for (_, branch) in sharedBranches.entries {
            let branchMax = branch.getCommitSequenceId(branch.trunk.getHead().revision).sequenceNumber
            if let current = maxSequenceNumber, current >= branchMax {
                continue
            }
            maxSequenceNumber = branchMax
        }
        return maxSequenceNumber
    }

    /// Advances the minimum sequence number and evicts trunk commits outside the collaboration window
    /// that no local branch or retention policy needs.
    public func advanceMinimumSequenceNumber(_ minimumSequenceNumber: Int, allowHistoryTrimming: Bool = true) throws {
        if minimumSequenceNumber == self.minimumSequenceNumber {
            return
        }

        precondition(minimumSequenceNumber > self.minimumSequenceNumber, "0x476: number must be larger or equal to current minimumSequenceNumber.")

        self.minimumSequenceNumber = minimumSequenceNumber
        if allowHistoryTrimming {
            try trimHistory()
        }
    }

    /// Uses the retention policy, minimum sequence number and registered branch bases to evict
    /// trunk commits that are no longer needed.
    private func trimHistory() throws {
        let msnBound = getUpperTrimmingBoundForMinimumSequenceNumber()
        let forkBound = try getUpperTrimmingBoundForLocalForks()
        let historyBound = try getUpperTrimmingBoundForHistory()
        let trunkTailSequenceId = minSequenceId(msnBound, minSequenceId(forkBound, historyBound))
        let mainBranch = try getSharedBranch(.main)

        let (sequenceId, latestEvicted) = mainBranch.getClosestTrunkCommit(
            maxSequenceId(trunkTailSequenceId, mainBranch.sequenceIdToCommit.minKey() ?? minimumPossibleSequenceId)
        )

        // Don't do any work if the commit found by the search is already the tail of the trunk
        if latestEvicted === trunkBase {
            return
        }

        // Performance mutation (TS): rather than regenerating the commit graph, chop the tail off.
        // Peer branches are rebased to at least the new base, the local branch is at the trunk
        // head and every other branch is tracked by `trunkBranches` and is at or ahead of it.
        let newTrunkBase = latestEvicted

        // collect the revisions that will be trimmed to send as part of the branch trimmed event
        let trimmedCommits = getPathFromBase(newTrunkBase, trunkBase)
        let trimmedRevisions = trimmedCommits.map(\.revision)

        // All peer branches are caught up to at least the tail commit; rebase them so none references
        // an evicted commit.
        try mainBranch.trimHistory(newBase: latestEvicted, sequenceId: sequenceId)

        // Custom metadata shares the lifetime of its commit. The new trunk base remains reachable as
        // the sentinel, so its metadata is cleared; fully evicted commits become traps.
        newTrunkBase.customMetadata = nil

        for commit in trimmedCommits.dropLast() {
            commit.evict()
        }

        // Dropping the parent removes references to the evicted commits. The trunk base's parent
        // stays readable (nil) so readers can find the root without checking `wasTrimmed`.
        newTrunkBase.parent = nil
        newTrunkBase.wasTrimmed = true
        trunkBase = newTrunkBase
        trimState.trimmedCommitCount += trimmedRevisions.count

        try trimmer.emit(trimmedRevisions)
    }

    public func isEmpty() -> Bool {
        for (_, branch) in sharedBranches.entries {
            if !branch.isEmpty(baseCommit: trunkBase) {
                return false
            }
        }

        return minimumSequenceNumber == minimumPossibleSequenceNumber
    }

    public func getSummaryData() throws -> SummaryData<Change> {
        // Trimming the trunk before serializing keeps the summarized trunk minimal.
        try trimHistory()

        let mainBranch = try getSharedBranch(.main)
        let minSeqNumberToSummarize = SequenceId(sequenceNumber: minimumSequenceNumber + 1)
        let historyBound = try getUpperTrimmingBoundForHistory()
        var minBaseSeqId = minSequenceId(
            minSeqNumberToSummarize,
            mainBranch.sequenceIdToCommit.nextHigherKey(historyBound) ?? minSeqNumberToSummarize
        )
        var branches = OrderedMap<BranchId, SharedBranchSummaryData<Change>>()
        for (branchId, branch) in sharedBranches.entries where branchId != .main {
            let branchSummary = try branch.getSummaryData(minSeqNumberToSummarize: minSeqNumberToSummarize, trunkBaseRevision: trunkBase.revision)
            branches[branchId] = branchSummary
            guard let base = branchSummary.base else {
                preconditionFailure("0xc57: Branch summary must have a base")
            }
            let baseSequenceId = mainBranch.getCommitSequenceId(base)
            minBaseSeqId = minSequenceId(minBaseSeqId, baseSequenceId)
        }
        let mainSummary = try mainBranch.getSummaryData(minSeqNumberToSummarize: minBaseSeqId, trunkBaseRevision: trunkBase.revision)
        return SummaryData(originator: localSessionId, main: mainSummary, branches: branches)
    }

    public func loadSummaryData(_ data: SummaryData<Change>) throws {
        precondition(isEmpty(), "0x68a: Attempted to load from summary after edit manager was already mutated")
        // Record each trunk commit's tag while generating the trunk, for hydrating peer branches.
        var trunkRevisionCache: [RevisionTag: GraphCommit<Change>] = [:]
        trunkRevisionCache[trunkBase.revision] = trunkBase
        guard let mainBranch = sharedBranches[.main] else {
            preconditionFailure("0xc58: Main branch must exist")
        }
        try mainBranch.loadSummaryData(data.main, trunkRevisionCache: &trunkRevisionCache)
        if let dataBranches = data.branches {
            for (branchId, branchData) in dataBranches.entries {
                guard let baseCommit = trunkRevisionCache[branchData.base ?? rootRevision] else {
                    preconditionFailure("0xd87: Expected summary branch base to be in trunk cache")
                }
                let branch = createSharedBranch(branchId, branchName: branchData.name, sessionId: branchData.session, parent: mainBranch, branch: try mainBranch.trunk.fork(baseCommit))
                try branch.loadSummaryData(branchData, trunkRevisionCache: &trunkRevisionCache)
                try addSharedBranch(branchId, branch)
            }
        }
        // Summaries do not include a minimum sequence number, so the loader conservatively retains
        // all revisions from the summary (TS leaves `this.trimHistory()` commented out here).
    }

    public func getTrunkHead(_ branchId: BranchId) throws -> GraphCommit<Change> {
        try getSharedBranch(branchId).trunk.getHead()
    }

    public func getTrunkChanges(_ branchId: BranchId) throws -> [Change] {
        try getTrunkCommits(branchId).map(\.change)
    }

    public func getTrunkCommits(_ branchId: BranchId) throws -> [GraphCommit<Change>] {
        getPathFromBase(try getTrunkHead(branchId), trunkBase)
    }

    public func getLocalCommits(_ branchId: BranchId) throws -> [GraphCommit<Change>] {
        try getSharedBranch(branchId).getLocalCommits()
    }

    /// The length of the longest peer or local branch, counted from its common ancestor with the trunk.
    public func getLongestBranchLength() -> Int {
        var maxLength = 0
        for (_, branch) in sharedBranches.entries {
            maxLength = max(maxLength, branch.getLongestBranchLength())
        }
        return maxLength
    }

    public func sequenceBranchCreation(sessionId: String, referenceSequenceNumber: Int, branchId: BranchId, branchName: String? = nil) throws {
        if sessionId == localSessionId {
            precondition(sharedBranches[branchId] != nil, "0xc59: Expected branch to already exist")
            return
        }

        let mainBranch = try getSharedBranch(.main)
        let branchTrunk = try mainBranch.rebasePeer(sessionId: sessionId, referenceSequenceNumber: referenceSequenceNumber).fork()
        try createAndAddSharedBranch(branchId, branchName: branchName, sessionId: sessionId, parent: mainBranch, branch: branchTrunk)
    }

    public func addNewBranch(_ branchId: BranchId, branchName: String? = nil) throws {
        let main = try getSharedBranch(.main)
        try createAndAddSharedBranch(branchId, branchName: branchName, sessionId: localSessionId, parent: main, branch: try getLocalBranch(.main).fork())
    }

    public func getSharedBranchIds() -> [BranchId] {
        sharedBranches.keys
    }

    public func removeBranch(_ branchId: BranchId) {
        precondition(branchId != .main, "0xc5b: Cannot remove main branch")
        let hadBranch = sharedBranches[branchId] != nil
        sharedBranches[branchId] = nil
        precondition(hadBranch, "0xc5c: Expected branch to exist")
    }

    @discardableResult
    private func createAndAddSharedBranch(_ branchId: BranchId, branchName: String?, sessionId: String?, parent: SharedBranch<Family>?, branch: SharedTreeBranch<Family>) throws -> SharedBranch<Family> {
        let sharedBranch = createSharedBranch(branchId, branchName: branchName, sessionId: sessionId, parent: parent, branch: branch)
        try addSharedBranch(branchId, sharedBranch)
        return sharedBranch
    }

    private func addSharedBranch(_ branchId: BranchId, _ branch: SharedBranch<Family>) throws {
        precondition(sharedBranches[branchId] == nil, "0xc5d: A branch with this ID already exists")
        sharedBranches[branchId] = branch

        // Track all forks of the local branch for trunk eviction: their lifetime and rebase frequency
        // are unknown, so their trunk requirements are monitored explicitly.
        onForkTransitive(branch.localBranch) { [unowned self] fork in
            try self.registerBranch(fork)
        }

        if branchId != .main {
            try registerBranch(branch.localBranch)
            onSharedBranchCreated?(branchId)
        }
    }

    private func createSharedBranch(_ branchId: BranchId, branchName: String?, sessionId: String?, parent: SharedBranch<Family>?, branch: SharedTreeBranch<Family>) -> SharedBranch<Family> {
        SharedBranch(
            parentBranch: parent,
            trunk: branch,
            id: branchId,
            branchName: branchName,
            sessionId: sessionId,
            baseCommitSequenceId: minimumPossibleSequenceId,
            changeFamily: changeFamily,
            mintRevisionTag: mintRevisionTag,
            branchTrimmer: trimmer,
            trimState: trimState
        )
    }

    /// Adds a bunch of sequenced changes: contiguous commits of one batch from one client, all based
    /// on the same reference sequence number and not interleaved with other messages.
    /// `allowHistoryTrimming` false defers trimming (detached edits).
    public func addSequencedChanges(_ newCommits: [GraphCommit<Change>], sessionId: String, sequenceNumber: Int, referenceSequenceNumber: Int, branchId: BranchId, allowHistoryTrimming: Bool = true) throws {
        precondition(!newCommits.isEmpty, "0xad8: Expected at least one sequenced change")
        precondition(sequenceNumber > minimumSequenceNumber, "0x713: Expected change sequence number to exceed the last known minimum sequence number")

        let branch = try getSharedBranch(branchId)

        let onSequenceLocalCommit: (GraphCommit<Change>, SequenceId, SequenceId) throws -> Void = { [unowned self] commit, sequenceId, previousSequenceId in
            try branch.localBranch.commitWasSequenced(commit)
            // Local forks based on the previous trunk head that branch off the local branch advance to
            // the new trunk head's sequence id: the whole local branch just advanced by this commit.
            // Forks that fell behind the local branch are based on older trunk commits and stay put.
            if let currentBranches = self.trunkBranches.get(previousSequenceId) {
                let newBranches = self.getOrCreateTrunkBranches(sequenceId)
                for forkedBranch in currentBranches.branches {
                    // Advance a fork whose head descends from the local commit that was just pushed.
                    if findAncestor(forkedBranch.getHead(), predicate: { $0 === commit }) != nil {
                        newBranches.add(forkedBranch)
                        _ = currentBranches.delete(forkedBranch)
                        try forkedBranch.commitWasSequenced(commit)
                    }
                }
                // Clean up our trunk branches map by removing any empty sets.
                if currentBranches.count == 0 {
                    self.trunkBranches.delete(previousSequenceId)
                }
                if newBranches.count == 0 {
                    self.trunkBranches.delete(sequenceId)
                }
            }
        }

        let areLocalCommits = sessionId == localSessionId
        try branch.addSequencedChanges(
            newCommits,
            sessionId: sessionId,
            sequenceNumber: sequenceNumber,
            areLocalCommits: areLocalCommits,
            referenceSequenceNumber: referenceSequenceNumber,
            onSequenceLocalCommit: onSequenceLocalCommit
        )
        if allowHistoryTrimming {
            try trimHistory()
        }
    }

    /// Finds the local commit with `revision` and the commits after it on the local branch.
    public func findLocalCommit(_ branchId: BranchId, revision: RevisionTag) throws -> (commit: GraphCommit<Change>, commitsAfter: [GraphCommit<Change>]) {
        var commits: [GraphCommit<Change>] = []
        let commit = findAncestor(try getSharedBranch(branchId).localBranch.getHead(), path: &commits) { $0.revision == revision }
        guard let commit else {
            preconditionFailure("0x599: Expected local branch to contain revision")
        }
        return (commit, commits)
    }
}

/// editManager.ts: getPathFromBase, the path from the base of a branch to its head.
func getPathFromBase<Change>(_ branchHead: GraphCommit<Change>, _ baseBranchHead: GraphCommit<Change>) -> [GraphCommit<Change>] {
    var path: [GraphCommit<Change>] = []
    precondition(findCommonAncestor(branchHead, path: &path, baseBranchHead) != nil, "0x573: Expected branches to be related")
    return path
}

/// editManager.ts: SharedBranch, a trunk with its peer branches and the local branch.
final class SharedBranch<Family: ChangeFamily> {
    typealias Change = Family.Rebaser.Change

    /// The changes made by this client which have not yet been confirmed as sequenced changes.
    let localBranch: SharedTreeBranch<Family>

    /// Each peer's local change list as of its latest known edit; heads stay in original form.
    private var peerLocalBranches = OrderedMap<String, SharedTreeBranch<Family>>()

    /// Sequence id to commit, including an entry for the trunk base (always the lowest key).
    let sequenceIdToCommit = BTree<SequenceId, GraphCommit<Change>>(compare: sequenceIdComparator)

    /// Commits on the local branch but not on the trunk, oldest first.
    private var localCommits: [GraphCommit<Change>] = []

    /// Sequenced-commit metadata; no entry for the trunk base.
    private var commitMetadata: [RevisionTag: (sequenceId: SequenceId, sessionId: String)] = [:]

    let parentBranch: SharedBranch<Family>?
    let trunk: SharedTreeBranch<Family>
    private let id: BranchId
    let branchName: String?
    private let sessionId: String?
    private let changeFamily: Family
    private let mintRevisionTag: () throws -> RevisionTag
    private let trimState: BranchTrimState

    init(
        parentBranch: SharedBranch<Family>?,
        trunk: SharedTreeBranch<Family>,
        id: BranchId,
        branchName: String?,
        sessionId: String?,
        baseCommitSequenceId: SequenceId,
        changeFamily: Family,
        mintRevisionTag: @escaping () throws -> RevisionTag,
        branchTrimmer: Emitter<[RevisionTag]>,
        trimState: BranchTrimState
    ) {
        self.parentBranch = parentBranch
        self.trunk = trunk
        self.id = id
        self.branchName = branchName
        self.sessionId = sessionId
        self.changeFamily = changeFamily
        self.mintRevisionTag = mintRevisionTag
        self.trimState = trimState
        localBranch = SharedTreeBranch(head: trunk.getHead(), changeFamily: changeFamily, mintRevisionTag: mintRevisionTag, trimState: trimState)
        localBranch.setTrimmer(branchTrimmer)

        sequenceIdToCommit.set(baseCommitSequenceId, trunk.getHead())

        localBranch.events.afterChange.on { [unowned self] event in
            if event.type == .append {
                self.localCommits.append(contentsOf: event.newCommits)
            } else {
                self.localCommits = []
                _ = findCommonAncestor(self.localBranch.getHead(), path: &self.localCommits, self.trunk.getHead())
            }
        }
    }

    func addSequencedChanges(
        _ newCommits: [GraphCommit<Change>],
        sessionId: String,
        sequenceNumber: Int,
        areLocalCommits: Bool,
        referenceSequenceNumber: Int,
        onSequenceLocalCommit: (GraphCommit<Change>, SequenceId, SequenceId) throws -> Void
    ) throws {
        // ">=" because changes in the same batch have the same sequence number
        precondition(
            sequenceNumber >= (sequenceIdToCommit.maxKey()?.sequenceNumber ?? minimumPossibleSequenceNumber),
            "0xa64: Attempted to sequence change with an outdated sequence number"
        )

        let batchSize = getBatchSize(sequenceNumber)
        // The sequence id for the next commit to be processed in the bunch.
        var nextSequenceId = batchSize == 0
            ? SequenceId(sequenceNumber: sequenceNumber)
            : SequenceId(sequenceNumber: sequenceNumber, indexInBatch: Double(batchSize))

        // Local changes are applied by fast forwarding the local branch commit onto the trunk.
        if areLocalCommits {
            for commit in newCommits {
                try sequenceLocalCommit(commit.revision, sequenceId: nextSequenceId, sessionId: sessionId, onSequenceLocalCommit: onSequenceLocalCommit)
                nextSequenceId = getNextSequenceId(nextSequenceId)
            }
            return
        }

        // Remote changes, step 1: recreate the peer's local environment by rebasing its branch over the
        // trunk up to the change's base. A no-op when the peer has not advanced since its last edit.
        let peerLocalBranch = try rebasePeer(sessionId: sessionId, referenceSequenceNumber: referenceSequenceNumber)

        // Step 2: append the changes to the peer branch and rebase them to the tip of the trunk.
        if peerLocalBranch.getHead() === trunk.getHead() {
            // A caught-up, empty peer branch: push the changes to the trunk directly and move the
            // peer branch to the trunk's head.
            for newCommit in newCommits {
                try pushCommitToTrunk(nextSequenceId, Commit(revision: newCommit.revision, change: newCommit.change, sessionId: sessionId, customMetadata: newCommit.customMetadata))
                nextSequenceId = getNextSequenceId(nextSequenceId)
            }
            peerLocalBranch.setHead(trunk.getHead(), commitCountDelta: newCommits.count)
        } else {
            // Otherwise, push the changes to the peer local branch and merge the branch into the trunk.
            for newCommit in newCommits {
                try peerLocalBranch.apply(tagChange(newCommit.change, newCommit.revision), kind: .defaultKind, customMetadata: newCommit.customMetadata)
            }
            if let sourceCommits = try trunk.merge(peerLocalBranch) {
                // The merge changed the trunk: record the rebased commits' sequence ids and metadata.
                for sourceCommit in sourceCommits {
                    sequenceIdToCommit.set(nextSequenceId, sourceCommit)
                    commitMetadata[sourceCommit.revision] = (nextSequenceId, sessionId)
                    nextSequenceId = getNextSequenceId(nextSequenceId)
                }
            }
        }

        // Step 3: rebase the local branch over the updated trunk.
        try localBranch.rebaseOnto(trunk)
    }

    func isEmpty(baseCommit: GraphCommit<Change>) -> Bool {
        trunk.getHead() === baseCommit && peerLocalBranches.isEmpty && localBranch.getHead() === trunk.getHead()
    }

    func rebasePeer(sessionId: String, referenceSequenceNumber: Int) throws -> SharedTreeBranch<Family> {
        let (_, baseRevisionInTrunk) = getClosestTrunkCommit(referenceSequenceNumber)
        let peerLocalBranch: SharedTreeBranch<Family>
        if let existing = peerLocalBranches[sessionId] {
            peerLocalBranch = existing
        } else {
            peerLocalBranch = SharedTreeBranch(head: baseRevisionInTrunk, changeFamily: changeFamily, mintRevisionTag: mintRevisionTag, trimState: trimState)
            peerLocalBranches[sessionId] = peerLocalBranch
        }
        try peerLocalBranch.rebaseOnto(trunk, upTo: baseRevisionInTrunk)
        return peerLocalBranch
    }

    func getPeerBranchOrTrunk(_ sessionId: String) -> SharedTreeBranch<Family> {
        peerLocalBranches[sessionId] ?? trunk
    }

    /// The length of the longest peer or local branch, counted from its common ancestor with the trunk.
    func getLongestBranchLength() -> Int {
        var maxLength = 0
        let trunkHead = trunk.getHead()
        for (_, branch) in peerLocalBranches.entries {
            let branchPath = getPathFromBase(branch.getHead(), trunkHead)
            if branchPath.count > maxLength {
                maxLength = branchPath.count
            }
        }
        let localPath = getPathFromBase(localBranch.getHead(), trunkHead)
        return max(maxLength, localPath.count)
    }

    func trimHistory(newBase: GraphCommit<Change>, sequenceId: SequenceId) throws {
        try rebasePeers(newBase)

        sequenceIdToCommit.editRange(minimumPossibleSequenceId, sequenceId, includeHigh: true) { s, commit in
            guard let commit else {
                preconditionFailure("sequence map holds a commit for every key")
            }
            // Cleanup look-aside data for each evicted commit
            commitMetadata[commit.revision] = nil
            // Delete every evicted commit except the latest one, which is the new trunk base
            if equalSequenceIds(s, sequenceId) {
                precondition(commit === newBase, "0x729: Expected last evicted commit to be new trunk base")
                return .keep
            }
            return .delete
        }

        let trunkSize = getPathFromBase(trunk.getHead(), newBase).count
        precondition(sequenceIdToCommit.count == trunkSize + 1, "0x744: The size of the sequenceMap must have one element more than the trunk")
        precondition(commitMetadata.count == trunkSize, "0x745: The size of the trunkMetadata must be the same as the trunk")
    }

    private func rebasePeers(_ commit: GraphCommit<Change>) throws {
        for (_, branch) in peerLocalBranches.entries {
            try branch.rebaseOnto(trunk, upTo: commit)
        }

        // The metadata for new trunk base revision needs to be deleted before modifying it.
        commitMetadata[commit.revision] = nil
    }

    func getLocalCommits() -> [GraphCommit<Change>] {
        localCommits
    }

    /// Promotes the oldest unsequenced local commit to the trunk head. A performance optimization
    /// (TS): rebasing the local branch over its own sequenced commit would be a no-op, so the commit
    /// moves straight from the local commit list to the trunk.
    private func sequenceLocalCommit(_ revision: RevisionTag, sequenceId: SequenceId, sessionId: String, onSequenceLocalCommit: (GraphCommit<Change>, SequenceId, SequenceId) throws -> Void) throws {
        if commitMetadata[revision] != nil {
            // A shared-branch commit concurrently merged by another client: already sequenced.
            return
        }

        // Push the local commit to the trunk. Only the `localCommits` cache changes; the local branch
        // catches up when it next rebases.
        precondition(!localCommits.isEmpty, "0x6b5: Received a sequenced change from the local session despite having no local changes")
        let firstLocalCommit = localCommits.removeFirst()

        let prevSequenceId = getCommitSequenceId(trunk.getHead().revision)
        pushGraphCommitToTrunk(sequenceId, firstLocalCommit, sessionId: sessionId)
        try onSequenceLocalCommit(firstLocalCommit, sequenceId, prevSequenceId)
    }

    /// The most recent trunk commit sequenced at or before `searchBy`; a sequence number selects the
    /// last commit of its batch.
    func getClosestTrunkCommit(_ searchBy: Int) -> (SequenceId, GraphCommit<Change>) {
        getClosestTrunkCommit(SequenceId(sequenceNumber: searchBy, indexInBatch: .infinity))
    }

    func getClosestTrunkCommit(_ sequenceId: SequenceId) -> (SequenceId, GraphCommit<Change>) {
        guard let pair = sequenceIdToCommit.getPairOrNextLower(sequenceId), let commit = pair.1 else {
            preconditionFailure("0x746: sequence id has been evicted")
        }
        return (pair.0, commit)
    }

    private func pushGraphCommitToTrunk(_ sequenceId: SequenceId, _ graphCommit: GraphCommit<Change>, sessionId: String) {
        trunk.setHead(graphCommit, commitCountDelta: 1)
        registerSequencedCommit(sequenceId, sessionId: sessionId, commit: graphCommit)
    }

    private func pushCommitToTrunk(_ sequenceId: SequenceId, _ commit: Commit<Change>) throws {
        let mintedCommit = mintCommit(trunk.getHead(), revision: commit.revision, change: commit.change, customMetadata: commit.customMetadata)
        pushGraphCommitToTrunk(sequenceId, mintedCommit, sessionId: commit.sessionId)
    }

    private func registerSequencedCommit(_ sequenceId: SequenceId, sessionId: String, commit: GraphCommit<Change>) {
        sequenceIdToCommit.set(sequenceId, commit)
        commitMetadata[commit.revision] = (sequenceId, sessionId)
    }

    func getCommitSequenceId(_ commitRevision: RevisionTag) -> SequenceId {
        commitMetadata[commitRevision]?.sequenceId ?? minimumPossibleSequenceId
    }

    /// Commits already recorded at `sequenceNumber`: a batch may arrive in more than one bunch.
    private func getBatchSize(_ sequenceNumber: Int) -> Int {
        let startSequenceId = SequenceId(sequenceNumber: sequenceNumber)
        let endSequenceId = SequenceId(sequenceNumber: sequenceNumber + 1)

        return sequenceIdToCommit.getRange(startSequenceId, endSequenceId, includeHigh: false).count
    }

    func getSummaryData(minSeqNumberToSummarize: SequenceId, trunkBaseRevision: RevisionTag) throws -> SharedBranchSummaryData<Change> {
        // Summarization only occurs on a client with no local or in-flight changes.
        precondition(localBranch.getHead() === trunk.getHead(), "0xc5e: Clients with local changes cannot be used to generate summaries")

        let parentHead: GraphCommit<Change>
        if let parentBranch {
            parentHead = parentBranch.trunk.getHead()
        } else {
            let oldestCommitInCollabWindow = getClosestTrunkCommit(minSeqNumberToSummarize).1
            // Path construction is exclusive, so use the parent of the oldest commit in the window if it exists
            parentHead = oldestCommitInCollabWindow.parent ?? oldestCommitInCollabWindow
        }

        var childBranchTrunkCommits: [GraphCommit<Change>] = []
        guard let forkPointFromMainTrunk = findCommonAncestor(trunk.getHead(), path: &childBranchTrunkCommits, parentHead) else {
            preconditionFailure("0xc5f: Expected child branch to be based on main branch")
        }

        let trunkCommits = childBranchTrunkCommits.map { c in
            guard let metadata = commitMetadata[c.revision] else {
                preconditionFailure("0xad5: Expected metadata for trunk commit")
            }
            return SequencedCommit(
                revision: c.revision,
                change: c.change,
                sessionId: metadata.sessionId,
                customMetadata: c.customMetadata,
                sequenceNumber: metadata.sequenceId.sequenceNumber,
                indexInBatch: metadata.sequenceId.indexInBatch
            )
        }

        var peers = OrderedMap<String, SummarySessionBranch<Change>>()
        for (sessionId, branch) in peerLocalBranches.entries {
            var branchPath: [GraphCommit<Change>] = []
            guard let ancestor = findCommonAncestor(branch.getHead(), path: &branchPath, trunk.getHead()) else {
                preconditionFailure("0xad6: Expected branch to be based on trunk")
            }

            let base = ancestor.revision == trunkBaseRevision ? rootRevision : ancestor.revision
            peers[sessionId] = SummarySessionBranch(
                base: base,
                commits: branchPath.map { c in
                    Commit(revision: c.revision, change: c.change, sessionId: sessionId, customMetadata: c.customMetadata)
                }
            )
        }

        return SharedBranchSummaryData(
            id: id,
            name: branchName,
            session: self.sessionId,
            author: nil,
            base: parentBranch == nil ? nil : forkPointFromMainTrunk.revision,
            trunk: trunkCommits,
            peerLocalBranches: peers
        )
    }

    func loadSummaryData(_ data: SharedBranchSummaryData<Change>, trunkRevisionCache: inout [RevisionTag: GraphCommit<Change>]) throws {
        precondition((parentBranch == nil) == (data.base == nil), "0xc60: Expected branch base to match presence of parent branch")
        var trunkHead = trunk.getHead()
        precondition(
            trunkHead.revision == (data.base ?? rootRevision) && localBranch.getHead() === trunkHead,
            "0xc61: Expected base revision to be in trunk cache"
        )
        for c in data.trunk {
            let sequenceId = c.indexInBatch == nil
                ? SequenceId(sequenceNumber: c.sequenceNumber)
                : SequenceId(sequenceNumber: c.sequenceNumber, indexInBatch: c.indexInBatch)
            let commit = mintCommit(trunkHead, revision: c.revision, change: c.change, customMetadata: c.customMetadata)
            sequenceIdToCommit.set(sequenceId, commit)
            commitMetadata[c.revision] = (sequenceId, c.sessionId)
            trunkRevisionCache[c.revision] = commit
            trunkHead = commit
        }
        trunk.setHead(trunkHead, commitCountDelta: data.trunk.count)

        localBranch.setHead(trunk.getHead(), commitCountDelta: data.trunk.count)

        for (sessionId, branch) in data.peerLocalBranches.entries {
            guard let commit = trunkRevisionCache[branch.base] else {
                preconditionFailure("0xad7: Expected summary branch to be based off of a revision in the trunk")
            }

            var branchHead = commit
            for c in branch.commits {
                branchHead = mintCommit(branchHead, revision: c.revision, change: c.change, customMetadata: c.customMetadata)
            }
            peerLocalBranches[sessionId] = SharedTreeBranch(head: branchHead, changeFamily: changeFamily, mintRevisionTag: mintRevisionTag, trimState: trimState)
        }
    }
}

/// editManager.ts getNextSequenceId: a bunch shares one sequence number, so only the index advances.
private func getNextSequenceId(_ sequenceId: SequenceId) -> SequenceId {
    SequenceId(sequenceNumber: sequenceId.sequenceNumber, indexInBatch: (sequenceId.indexInBatch ?? 0) + 1)
}
