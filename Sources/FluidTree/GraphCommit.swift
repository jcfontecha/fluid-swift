import FluidJS

/// core/rebase/types.ts: CustomMetadataTree.
/// Metadata a transaction attaches to its commit; child trees come from nested transactions.
public struct CustomMetadataTree: Equatable {
    public var metadata: JSObject<JSONValue>?
    public var children: [CustomMetadataTree]
    public init(metadata: JSObject<JSONValue>?, children: [CustomMetadataTree]) {
        self.metadata = metadata
        self.children = children
    }
}

/// core/rebase/types.ts: CommitKind.
public enum CommitKind: Int {
    case defaultKind = 0
    case undo = 1
    case redo = 2
}

/// core/rebase/types.ts: GraphCommit.
/// A commit in a graph of commits linked by parent pointers. Commits are compared by identity
/// (`===`), as in TS, so this is a class.
public final class GraphCommit<Change> {
    private let storedRevision: RevisionTag
    /// nil only once evicted.
    private var storedChange: Change?
    private var storedParent: GraphCommit<Change>?
    private var storedCustomMetadata: CustomMetadataTree?
    /// True when this commit was evicted from the trunk and is no longer part of any branch.
    private var isEvicted = false
    /// The commit was trimmed from the trunk (it is, or was, the trunk base).
    public internal(set) var wasTrimmed = false
    /// core/rebase/utils.ts: the `Rollback` WeakMap entry associated with this commit object.
    var rollback: TaggedChange<Change>?

    public init(revision: RevisionTag, change: Change, parent: GraphCommit<Change>?, customMetadata: CustomMetadataTree?) {
        storedRevision = revision
        storedChange = change
        storedParent = parent
        storedCustomMetadata = customMetadata
    }

    public var revision: RevisionTag {
        precondition(!isEvicted, "0xa5f: Should not access 'revision' property of an evicted commit")
        return storedRevision
    }

    public var change: Change {
        guard let storedChange else {
            preconditionFailure("0xa5e: Should not access 'change' property of an evicted commit")
        }
        return storedChange
    }

    public internal(set) var parent: GraphCommit<Change>? {
        get {
            precondition(!isEvicted, "0xa60: Should not access 'parent' property of an evicted commit")
            return storedParent
        }
        set {
            storedParent = newValue
        }
    }

    public internal(set) var customMetadata: CustomMetadataTree? {
        get {
            precondition(!isEvicted, "0xd36: Should not access 'customMetadata' property of an evicted commit")
            return storedCustomMetadata
        }
        set {
            storedCustomMetadata = newValue
        }
    }

    /// editManager.ts trimHistory: an evicted commit's intrinsic properties are replaced with
    /// throwing getters (asserts 0xa5e, 0xa5f, 0xd36, 0xa60), which also drops its references so
    /// the evicted history can be freed.
    func evict() {
        isEvicted = true
        storedChange = nil
        storedParent = nil
        storedCustomMetadata = nil
        rollback = nil
        wasTrimmed = true
    }
}

/// core/rebase/types.ts: mintCommit. Creates a new commit object (with no rollback cached).
public func mintCommit<Change>(_ parent: GraphCommit<Change>, revision: RevisionTag, change: Change, customMetadata: CustomMetadataTree?) -> GraphCommit<Change> {
    GraphCommit(revision: revision, change: change, parent: parent, customMetadata: customMetadata)
}

/// core/rebase/types.ts: mintCommit called with another commit as the template.
public func mintCommit<Change>(_ parent: GraphCommit<Change>, _ commit: GraphCommit<Change>) -> GraphCommit<Change> {
    mintCommit(parent, revision: commit.revision, change: commit.change, customMetadata: commit.customMetadata)
}
