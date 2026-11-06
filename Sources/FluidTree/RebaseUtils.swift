import FluidJS

/// core/rebase/utils.ts: RebasedCommits.
/// For source branch Y (D-E) rebased onto X (A-B-C): deletedSourceCommits [D, E],
/// targetCommits [B, C], sourceCommits [D', E'].
public struct RebasedCommits<Change> {
    public var deletedSourceCommits: [GraphCommit<Change>]
    public var targetCommits: [GraphCommit<Change>]
    public var sourceCommits: [GraphCommit<Change>]
}

/// core/rebase/utils.ts: RebaseStats.
public struct RebaseStats: Equatable {
    public let sourceBranchLength: Int
    public let rebaseDistance: Int
    public let countDropped: Int
}

/// core/rebase/utils.ts: BranchRebaseResult.
/// `sourceChange` is a lazily computed, cached property, as `defineLazyCachedProperty` makes it in TS.
public final class BranchRebaseResult<Change> {
    public let newSourceHead: GraphCommit<Change>
    public let commits: RebasedCommits<Change>
    public let telemetryProperties: RebaseStats
    private let computeSourceChange: () throws -> Change?
    private var cachedSourceChange: Change??

    init(newSourceHead: GraphCommit<Change>, commits: RebasedCommits<Change>, telemetryProperties: RebaseStats, sourceChange: @escaping () throws -> Change?) {
        self.newSourceHead = newSourceHead
        self.commits = commits
        self.telemetryProperties = telemetryProperties
        computeSourceChange = sourceChange
    }

    /// The cumulative change to the source branch (nil if no change occurred).
    public func sourceChange() throws -> Change? {
        if let cachedSourceChange {
            return cachedSourceChange
        }
        let change = try computeSourceChange()
        cachedSourceChange = .some(change)
        return change
    }
}

/// core/rebase/utils.ts: rebaseBranch.
/// Rebases the branch at `sourceHead` onto `targetCommit` of the branch at `targetHead`
/// (`targetHead` defaults to `targetCommit`). Source commits whose revisions appear on the target
/// branch cancel out, and the new base advances past matching commits directly after `targetCommit`.
public func rebaseBranch<Family: ChangeFamily>(
    mintRevisionTag: () throws -> RevisionTag,
    changeFamily: Family,
    sourceHead: GraphCommit<Family.Rebaser.Change>,
    targetCommit: GraphCommit<Family.Rebaser.Change>,
    targetHead: GraphCommit<Family.Rebaser.Change>? = nil
) throws -> BranchRebaseResult<Family.Rebaser.Change> {
    typealias Commit = GraphCommit<Family.Rebaser.Change>
    let targetHead = targetHead ?? targetCommit
    // Get both source and target as path arrays
    var sourcePath: [Commit] = []
    var targetPath: [Commit] = []
    let ancestor = findCommonAncestor(sourceHead, path: &sourcePath, targetHead, path: &targetPath)
    guard ancestor != nil else {
        throw JSONDecodingError("0x675: branches must be related")
    }

    let sourceBranchLength = sourcePath.count

    // Find where `targetCommit` is in the target branch
    guard let targetCommitIndex = targetPath.firstIndex(where: { $0 === targetCommit }) else {
        // The target commit is disjoint from the target or behind/at the divergence point,
        // so there is nothing more to rebase. (TS: `targetCommitIndex + 1` with index -1.)
        return BranchRebaseResult(
            newSourceHead: sourceHead,
            commits: RebasedCommits(deletedSourceCommits: [], targetCommits: [], sourceCommits: sourcePath),
            telemetryProperties: RebaseStats(sourceBranchLength: sourceBranchLength, rebaseDistance: 0, countDropped: 0),
            sourceChange: { nil }
        )
    }

    // Commits found on the target branch are skipped when processing the source branch because they
    // have already been rebased onto the target. Matching commits directly after `targetCommit`
    // advance the new base without any work.
    var sourceSet = Set(sourcePath.map(\.revision))
    var newBaseIndex = targetCommitIndex

    for (i, commit) in targetPath.enumerated() {
        if sourceSet.contains(commit.revision) {
            sourceSet.remove(commit.revision)
            newBaseIndex = max(newBaseIndex, i)
        } else if i > targetCommitIndex {
            break
        }
    }

    /// The commit on the target branch that the new source branch branches off of (the new common ancestor)
    let newBase = targetPath[newBaseIndex]
    // Figure out how much of the trunk to start rebasing over.
    let targetCommits = Array(targetPath[0...newBaseIndex])
    let deletedSourceCommits = sourcePath

    // A common prefix of identical revisions on the source and target rebase paths is equivalent on
    // both branches and doesn't need to be rebased. (TS keeps comparing the first elements without
    // breaking on a mismatch; this mirrors that loop.)
    var targetRebasePath = targetCommits
    if !sourcePath.isEmpty && !targetRebasePath.isEmpty {
        let minLength = min(sourcePath.count, targetRebasePath.count)
        for _ in 0..<minLength {
            if sourcePath[0].revision == targetRebasePath[0].revision {
                sourcePath.removeFirst()
                targetRebasePath.removeFirst()
            }
        }
    }

    var sourceCommits: [Commit] = []
    let telemetry = RebaseStats(sourceBranchLength: sourceBranchLength, rebaseDistance: targetCommits.count, countDropped: sourceBranchLength - sourceSet.count)

    // If the commits to rebase over already begin the source branch, in order and without interleaving,
    // they are dropped from the source branch and the remaining source commits are reparented onto the new base.
    if targetRebasePath.isEmpty {
        for commit in sourcePath {
            sourceCommits.append(mintCommit(sourceCommits.last ?? newBase, commit))
        }
        return BranchRebaseResult(
            newSourceHead: sourceCommits.last ?? newBase,
            commits: RebasedCommits(deletedSourceCommits: deletedSourceCommits, targetCommits: targetCommits, sourceCommits: sourceCommits),
            telemetryProperties: telemetry,
            sourceChange: { nil }
        )
    }

    let changeRebaser = changeFamily.rebaser
    // For each source commit, rebase backwards over the inverses of any commits already rebased, and then
    // rebase forwards over the rest of the commits up to the new base before advancing the new base.
    var newHead = newBase
    var revInfos = getRevInfoFromTaggedChanges((targetRebasePath + sourcePath).map(taggedCommit))
    // TS hands rebase a metadata source that reads `revInfos` live; a snapshot taken at each rebase
    // call observes exactly the same entries.
    var editsToCompose: [TaggedChange<Family.Rebaser.Change>] = targetRebasePath.map(taggedCommit)
    for commit in sourcePath {
        let rollback = try rollbackFromCommit(changeRebaser, commit, mintRevisionTag: mintRevisionTag, cache: true)
        if sourceSet.contains(commit.revision) {
            let currentComposedEdit = makeAnonChange(try changeRebaser.compose(editsToCompose))
            editsToCompose = [currentComposedEdit]
            let change = try changeRebaser.rebase(taggedCommit(commit), over: currentComposedEdit, metadata: RevisionMetadataSource(revInfos), ignoreNoChangeViolation: false)
            newHead = GraphCommit(revision: commit.revision, change: change, parent: newHead, customMetadata: commit.customMetadata)
            sourceCommits.append(newHead)
            editsToCompose.append(tagChange(change, commit.revision))
        }
        revInfos.append(RevisionInfo(revision: commit.revision))
        editsToCompose.insert(rollback, at: 0)
        revInfos.insert(RevisionInfo(revision: rollback.revision ?? commit.revision, rollbackOf: rollback.rollbackOf), at: 0)
    }

    let composeEdits = editsToCompose
    return BranchRebaseResult(
        newSourceHead: newHead,
        commits: RebasedCommits(deletedSourceCommits: deletedSourceCommits, targetCommits: targetCommits, sourceCommits: sourceCommits),
        telemetryProperties: telemetry,
        sourceChange: {
            let composed = try changeRebaser.compose(composeEdits)
            // cheapRebaseValidation("Malformed rebase net change", ...)
            try changeFamily.validator(composed)
            return composed
        }
    )
}

/// A commit viewed as the `TaggedChange` it structurally is in TS.
func taggedCommit<Change>(_ commit: GraphCommit<Change>) -> TaggedChange<Change> {
    TaggedChange(change: commit.change, revision: commit.revision)
}

/// core/rebase/utils.ts: getRevInfoFromTaggedChanges (the utils.ts copy, which records only
/// revision and rollbackOf).
func getRevInfoFromTaggedChanges<Change>(_ changes: [TaggedChange<Change>]) -> [RevisionInfo] {
    var revInfos: [RevisionInfo] = []
    for taggedChange in changes {
        if let revision = taggedChange.revision {
            revInfos.append(RevisionInfo(revision: revision, rollbackOf: taggedChange.rollbackOf))
        }
    }
    return revInfos
}

/// core/rebase/utils.ts: rollbackFromCommit. The revision is minted before inverting, and a cached
/// rollback lives on the commit object (the `Rollback` WeakMap).
func rollbackFromCommit<Rebaser: ChangeRebaser>(
    _ changeRebaser: Rebaser,
    _ commit: GraphCommit<Rebaser.Change>,
    mintRevisionTag: () throws -> RevisionTag,
    cache: Bool
) throws -> TaggedChange<Rebaser.Change> {
    if let cachedRollback = commit.rollback {
        return cachedRollback
    }
    let tag = try mintRevisionTag()
    let rollback = tagRollbackInverse(try changeRebaser.invert(taggedCommit(commit), isRollback: true, revision: tag), revision: tag, rollbackOf: commit.revision)
    if cache {
        commit.rollback = rollback
    }
    return rollback
}

/// core/rebase/utils.ts: findAncestor without a predicate finds the furthest ancestor (the root).
public func findAncestor<Change>(_ descendant: GraphCommit<Change>?) -> GraphCommit<Change>? {
    findAncestor(descendant) { $0.parent == nil }
}

/// core/rebase/utils.ts: findAncestor without a predicate, with a path.
public func findAncestor<Change>(_ descendant: GraphCommit<Change>?, path: inout [GraphCommit<Change>]) -> GraphCommit<Change>? {
    findAncestor(descendant, path: &path) { $0.parent == nil }
}

/// core/rebase/utils.ts: findAncestor, the closest ancestor (or `descendant` itself) satisfying `predicate`.
public func findAncestor<Change>(_ descendant: GraphCommit<Change>?, predicate: (GraphCommit<Change>) throws -> Bool) rethrows -> GraphCommit<Change>? {
    var path: [GraphCommit<Change>]? = nil
    return try findAncestorCore(descendant, path: &path, predicate: predicate)
}

/// core/rebase/utils.ts: findAncestor with a path. `path` receives the ancestry of `descendant`
/// from most distant to closest, excluding the ancestor found by `predicate`.
public func findAncestor<Change>(_ descendant: GraphCommit<Change>?, path: inout [GraphCommit<Change>], predicate: (GraphCommit<Change>) throws -> Bool) rethrows -> GraphCommit<Change>? {
    var optionalPath: [GraphCommit<Change>]? = path
    defer { path = optionalPath ?? [] }
    return try findAncestorCore(descendant, path: &optionalPath, predicate: predicate)
}

private func findAncestorCore<Change>(_ descendant: GraphCommit<Change>?, path: inout [GraphCommit<Change>]?, predicate: (GraphCommit<Change>) throws -> Bool) rethrows -> GraphCommit<Change>? {
    var current = descendant
    while let commit = current {
        if try predicate(commit) {
            path?.reverse()
            return commit
        }
        path?.append(commit)
        current = commit.parent
    }
    if path != nil {
        path = []
    }
    return nil
}

/// core/rebase/utils.ts: findCommonAncestor without paths.
public func findCommonAncestor<Change>(_ descendantA: GraphCommit<Change>?, _ descendantB: GraphCommit<Change>?) -> GraphCommit<Change>? {
    var pathA: [GraphCommit<Change>]? = nil
    var pathB: [GraphCommit<Change>]? = nil
    return findCommonAncestorCore(descendantA, &pathA, descendantB, &pathB)
}

/// core/rebase/utils.ts: findCommonAncestor with a path for `descendantA`, which receives the chain
/// of commits from the ancestor (exclusive) to `descendantA`.
public func findCommonAncestor<Change>(_ descendantA: GraphCommit<Change>?, path: inout [GraphCommit<Change>], _ descendantB: GraphCommit<Change>?) -> GraphCommit<Change>? {
    precondition(path.isEmpty, "0x578: Path A must be empty")
    var pathA: [GraphCommit<Change>]? = []
    var pathB: [GraphCommit<Change>]? = nil
    defer { path = pathA ?? [] }
    return findCommonAncestorCore(descendantA, &pathA, descendantB, &pathB)
}

/// core/rebase/utils.ts: findCommonAncestor with paths for both descendants.
public func findCommonAncestor<Change>(_ descendantA: GraphCommit<Change>?, path pathAOut: inout [GraphCommit<Change>], _ descendantB: GraphCommit<Change>?, path pathBOut: inout [GraphCommit<Change>]) -> GraphCommit<Change>? {
    precondition(pathAOut.isEmpty, "0x578: Path A must be empty")
    precondition(pathBOut.isEmpty, "0x579: Path B must be empty")
    var pathA: [GraphCommit<Change>]? = []
    var pathB: [GraphCommit<Change>]? = []
    defer {
        pathAOut = pathA ?? []
        pathBOut = pathB ?? []
    }
    return findCommonAncestorCore(descendantA, &pathA, descendantB, &pathB)
}

private func findCommonAncestorCore<Change>(_ descendantA: GraphCommit<Change>?, _ pathA: inout [GraphCommit<Change>]?, _ descendantB: GraphCommit<Change>?, _ pathB: inout [GraphCommit<Change>]?) -> GraphCommit<Change>? {
    var a = descendantA
    var b = descendantB
    if a === b {
        return a
    }

    var visited = Set<ObjectIdentifier>()
    while a != nil || b != nil {
        if let commitA = a {
            if visited.contains(ObjectIdentifier(commitA)) {
                if let index = pathB?.firstIndex(where: { $0 === commitA }) {
                    pathB?.removeSubrange(index...)
                }
                pathA?.reverse()
                pathB?.reverse()
                return commitA
            }
            visited.insert(ObjectIdentifier(commitA))
            pathA?.append(commitA)
            a = commitA.parent
        }

        if let commitB = b {
            if visited.contains(ObjectIdentifier(commitB)) {
                if let index = pathA?.firstIndex(where: { $0 === commitB }) {
                    pathA?.removeSubrange(index...)
                }
                pathA?.reverse()
                pathB?.reverse()
                return commitB
            }
            visited.insert(ObjectIdentifier(commitB))
            pathB?.append(commitB)
            b = commitB.parent
        }
    }

    if pathA != nil {
        pathA = []
    }
    if pathB != nil {
        pathB = []
    }
    return nil
}
