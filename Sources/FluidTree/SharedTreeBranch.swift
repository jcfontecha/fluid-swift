import FluidJS

/// shared-tree-core/branch.ts: BranchId (`SessionSpaceCompressedId | "main"`).
public enum BranchId: Hashable {
    case main
    case compressed(Double)
}

/// shared-tree-core/branch.ts: SharedTreeBranchChange.
/// Append: commits added to the head (an edit or a merge). Remove: commits removed from the head.
/// Rebase: commits from another branch added and existing commits replaced by rebased versions.
/// `change()` is the net change to the branch, computed lazily as in TS (nil only for a rebase
/// with no net change).
public struct SharedTreeBranchChange<Change> {
    public enum ChangeType {
        case append
        case remove
        case rebase
    }
    public let type: ChangeType
    /// The kind of an append; nil for remove and rebase.
    public let kind: CommitKind?
    public let newCommits: [GraphCommit<Change>]
    public let removedCommits: [GraphCommit<Change>]
    private let computeChange: () throws -> TaggedChange<Change>?

    init(type: ChangeType, kind: CommitKind?, newCommits: [GraphCommit<Change>], removedCommits: [GraphCommit<Change>], change: @escaping () throws -> TaggedChange<Change>?) {
        self.type = type
        self.kind = kind
        self.newCommits = newCommits
        self.removedCommits = removedCommits
        computeChange = change
    }

    public func change() throws -> TaggedChange<Change>? {
        try computeChange()
    }
}

/// shared-tree-core/branch.ts: BranchTrimState.
/// Branches whose ancestry is trimmed together share one instance, so every branch's commit
/// count updates without visiting each branch.
public final class BranchTrimState {
    /// The cumulative number of commits trimmed from the shared ancestry.
    public internal(set) var trimmedCommitCount = 0
    public init() {}
}

/// shared-tree-core/branch.ts: SharedTreeBranchEvents (including BranchTrimmingEvents).
public final class SharedTreeBranchEvents<Family: ChangeFamily> {
    public typealias Change = Family.Rebaser.Change
    /// Fired just before the head of the branch changes.
    public let beforeChange = Emitter<SharedTreeBranchChange<Change>>()
    /// Fired just after the head of the branch changes.
    public let afterChange = Emitter<SharedTreeBranchChange<Change>>()
    /// Fired when the branch forks.
    public let fork = Emitter<SharedTreeBranch<Family>>()
    /// Fired when a commit is ordered by the sequencing service.
    public let commitSequenced = Emitter<GraphCommit<Change>>()
    /// Fired after the branch is disposed.
    public let dispose = Emitter<Void>()
    /// Fired when a contiguous range of commits at the global tail of the branch is trimmed.
    public let ancestryTrimmed = Emitter<[RevisionTag]>()
}

/// shared-tree-core/branch.ts: SharedTreeBranch.
/// Tracks a linear history of commits ending at a head commit. A branch can be forked, can merge
/// another branch's divergent commits, and can rebase its divergent commits onto another branch.
public final class SharedTreeBranch<Family: ChangeFamily> {
    public typealias Change = Family.Rebaser.Change

    public let events = SharedTreeBranchEvents<Family>()
    public let changeFamily: Family
    private var head: GraphCommit<Change>
    private let mintRevisionTag: () throws -> RevisionTag
    private let trimState: BranchTrimState
    private var disposed = false
    /// The cached commit count before subtracting `trimState.trimmedCommitCount`; nil until first
    /// requested or inherited from a fork's parent.
    private var logicalCommitCount: Int?
    /// The source of ancestry trimming notifications for this branch.
    private var branchTrimmer: Emitter<[RevisionTag]>?
    private var unsubscribeBranchTrimmer: (() -> Void)?

    /// TS builds the editor in the constructor; the change family's `buildEditor` has no side
    /// effects, so building it on first use is equivalent.
    public private(set) lazy var editor: Family.Editor = changeFamily.buildEditor(mintRevisionTag: mintRevisionTag) { [unowned self] change in
        try self.apply(change, kind: .defaultKind, customMetadata: nil)
    }

    public init(head: GraphCommit<Change>, changeFamily: Family, mintRevisionTag: @escaping () throws -> RevisionTag, trimState: BranchTrimState) {
        self.head = head
        self.changeFamily = changeFamily
        self.mintRevisionTag = mintRevisionTag
        self.trimState = trimState
    }

    /// branch.ts `set trimmer`: replacing or clearing the trimmer removes the previous subscription.
    /// Setting a trimmer on a disposed branch is an error.
    public func setTrimmer(_ trimmer: Emitter<[RevisionTag]>?) {
        if trimmer != nil {
            assertNotDisposed()
        }
        unsubscribeBranchTrimmer?()
        branchTrimmer = trimmer
        unsubscribeBranchTrimmer = trimmer?.on { [weak self] revisions in
            try self?.events.ancestryTrimmed.emit(revisions)
        }
    }

    /// Sets the head without emitting change events.
    public func setHead(_ head: GraphCommit<Change>, commitCountDelta: Int) {
        assertNotDisposed()
        if head === self.head {
            return
        }
        if let count = logicalCommitCount {
            logicalCommitCount = count + commitCountDelta
        }
        self.head = head
    }

    /// Applies a change to this branch as a new head commit.
    public func apply(_ change: TaggedChange<Change>, kind: CommitKind, customMetadata: CustomMetadataTree?) throws {
        assertNotDisposed()

        guard let revisionTag = change.revision else {
            throw JSONDecodingError("0xa49: Revision tag must be provided")
        }

        let newHead = mintCommit(head, revision: revisionTag, change: change.change, customMetadata: customMetadata)

        let changeEvent = SharedTreeBranchChange(type: .append, kind: kind, newCommits: [newHead], removedCommits: []) { change }

        try events.beforeChange.emit(changeEvent)
        setHead(newHead, commitCountDelta: 1)
        try events.afterChange.emit(changeEvent)
    }

    /// Notifies the branch that a commit has been sequenced by the sequencing service.
    public func commitWasSequenced(_ commit: GraphCommit<Change>) throws {
        try events.commitSequenced.emit(commit)
    }

    public func getHead() -> GraphCommit<Change> {
        head
    }

    /// The number of commits in this branch, including ancestor branches but excluding the root sentinel.
    public func getCommitCount() -> Int {
        assertNotDisposed()
        let trimmedCommitCount = trimState.trimmedCommitCount
        if logicalCommitCount == nil {
            var count = -1 // Exclude the sentinel commit at the root.
            var commit: GraphCommit<Change>? = head
            while let current = commit {
                count += 1
                commit = current.parent
            }
            logicalCommitCount = count + trimmedCommitCount
        }
        return (logicalCommitCount ?? 0) - trimmedCommitCount
    }

    /// Spawns a new branch based on `commit` (default: this branch's head).
    public func fork(_ commit: GraphCommit<Change>? = nil, mintRevisionTag: (() throws -> RevisionTag)? = nil) throws -> SharedTreeBranch<Family> {
        assertNotDisposed()
        let commit = commit ?? head
        let fork = SharedTreeBranch(head: commit, changeFamily: changeFamily, mintRevisionTag: mintRevisionTag ?? self.mintRevisionTag, trimState: trimState)
        if commit === head {
            fork.logicalCommitCount = logicalCommitCount
        }
        fork.setTrimmer(branchTrimmer)
        try events.fork.emit(fork)
        return fork
    }

    /// Rebases this branch's divergent commits over `branch`, up to `upTo` (inclusive; default its head).
    public func rebaseOnto(_ branch: SharedTreeBranch<Family>, upTo: GraphCommit<Change>? = nil) throws {
        assertNotDisposed()

        // Rebase this branch onto the given branch
        guard let rebaseResult = try rebaseBranch(self, onto: branch, upTo: upTo ?? branch.getHead()) else {
            return
        }

        // The net change to this branch is provided by the `rebaseBranch` API
        let commits = rebaseResult.commits
        precondition(!commits.targetCommits.isEmpty, "0xa83: Expected commit(s) for a non no-op rebase")

        let newCommits = commits.targetCommits + commits.sourceCommits
        let changeEvent = SharedTreeBranchChange(type: .rebase, kind: nil, newCommits: newCommits, removedCommits: commits.deletedSourceCommits) {
            try rebaseResult.sourceChange().map(makeAnonChange)
        }

        try events.beforeChange.emit(changeEvent)
        setHead(rebaseResult.newSourceHead, commitCountDelta: newCommits.count - commits.deletedSourceCommits.count)
        try events.afterChange.emit(changeEvent)
    }

    /// Removes all commits after (not including) `commit`.
    public func removeAfter(_ commit: GraphCommit<Change>) throws {
        if commit === head {
            return
        }

        var removedCommits: [GraphCommit<Change>] = []
        var inverses: [TaggedChange<Change>] = []
        _ = try findAncestor(head, path: &removedCommits) { c in
            if c !== commit {
                let revision = try mintRevisionTag()
                let inverse = try changeFamily.rebaser.invert(taggedCommit(c), isRollback: true, revision: revision)
                inverses.append(tagRollbackInverse(inverse, revision: revision, rollbackOf: c.revision))
                return false
            }
            return true
        }
        precondition(!removedCommits.isEmpty, "0xa84: Commit must be in the branch's ancestry")

        let change = makeAnonChange(try changeFamily.rebaser.compose(inverses))
        let changeEvent = SharedTreeBranchChange(type: .remove, kind: nil, newCommits: [], removedCommits: removedCommits) { change }

        try events.beforeChange.emit(changeEvent)
        setHead(commit, commitCountDelta: -removedCommits.count)
        try events.afterChange.emit(changeEvent)
    }

    /// Applies all the divergent changes on `branch` to this branch; nil when nothing changed.
    @discardableResult
    public func merge(_ branch: SharedTreeBranch<Family>) throws -> [GraphCommit<Change>]? {
        assertNotDisposed()
        branch.assertNotDisposed()

        if branch === self {
            return nil
        }

        // Rebase the given branch onto this branch
        guard let rebaseResult = try rebaseBranch(branch, onto: self, upTo: getHead()) else {
            return nil
        }

        // Compute the net change to this branch
        let sourceCommits = rebaseResult.commits.sourceCommits
        precondition(!sourceCommits.isEmpty, "0xa86: Expected source commits in non no-op merge")
        let rebaser = changeFamily.rebaser
        // defineLazyCachedProperty: composed on first read, then cached.
        var cachedChange: TaggedChange<Change>?
        let changeEvent = SharedTreeBranchChange(type: .append, kind: .defaultKind, newCommits: sourceCommits, removedCommits: []) {
            if let cachedChange {
                return cachedChange
            }
            let change = makeAnonChange(try rebaser.compose(sourceCommits.map(taggedCommit)))
            cachedChange = change
            return change
        }

        try events.beforeChange.emit(changeEvent)
        setHead(rebaseResult.newSourceHead, commitCountDelta: sourceCommits.count)
        try events.afterChange.emit(changeEvent)
        return sourceCommits
    }

    /// Rebases `branch`'s head onto `onto`, returning nil if nothing changed.
    private func rebaseBranch(_ branch: SharedTreeBranch<Family>, onto: SharedTreeBranch<Family>, upTo: GraphCommit<Change>) throws -> BranchRebaseResult<Change>? {
        let branchHead = branch.head
        if branchHead === upTo {
            return nil
        }

        let output = try FluidTree.rebaseBranch(mintRevisionTag: mintRevisionTag, changeFamily: changeFamily, sourceHead: branchHead, targetCommit: upTo, targetHead: onto.getHead())

        if head === output.newSourceHead {
            return nil
        }

        return output
    }

    /// Disposes this branch, preventing further mutation. Calling it more than once has no effect.
    public func dispose() throws {
        if disposed {
            return
        }

        setTrimmer(nil)

        disposed = true
        try events.dispose.emit(())
    }

    private func assertNotDisposed() {
        precondition(!disposed, "0x66e: Branch is disposed")
    }
}

/// shared-tree-core/branch.ts: onForkTransitive. Fires `onFork` when `branch` forks, and when
/// those forks fork, transitively. Returns a function that deregisters every registration.
@discardableResult
public func onForkTransitive<Family: ChangeFamily>(_ branch: SharedTreeBranch<Family>, _ onFork: @escaping (SharedTreeBranch<Family>) throws -> Void) -> () -> Void {
    let offs = ListenerRemovals()
    offs.all.append(branch.events.fork.on { fork in
        offs.all.append(onForkTransitive(fork, onFork))
        try onFork(fork)
    })
    return {
        for off in offs.all {
            off()
        }
    }
}

/// Deregistration functions that listeners themselves append to (a JS closure-captured array).
final class ListenerRemovals {
    var all: [() -> Void] = []
}
