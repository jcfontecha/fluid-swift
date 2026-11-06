import FluidDriverDefinitions
import FluidJS

/// Ports driver-utils/src/protocol/gitHelper.ts `buildGitTreeHierarchy`: rebuild the snapshot
/// tree from git's flat, breadth-first tree listing. Lives in this driver because no driver-utils
/// target exists.
public func buildGitTreeHierarchy(
    _ flatTree: Git.ITree, blobsShaToPathCache: inout [String: String], removeAppTreePrefix: Bool
) throws -> ISnapshotTreeEx {
    let root = GitTreeNode(id: flatTree.sha, isRoot: true)
    var lookup: [String: GitTreeNode] = ["": root]
    for entry in flatTree.tree {
        var entryPath = entry.path.description
        if removeAppTreePrefix, entryPath.hasPrefix(".app/") {
            entryPath.removeFirst(".app/".count)
        }
        let lastSlash = entryPath.lastIndex(of: "/")
        let entryPathDir = lastSlash.map { String(entryPath[..<$0]) } ?? ""
        let entryPathBase = lastSlash.map { String(entryPath[entryPath.index(after: $0)...]) } ?? entryPath
        // The flat output is breadth-first, so a tree is listed before its contents.
        guard let node = lookup[entryPathDir] else {
            throw JSONDecodingError("Cannot read properties of undefined (reading '\(entryPathDir)')")
        }
        guard let name = entryPathBase.removingPercentEncoding else {
            throw JSONDecodingError("URIError: URI malformed")
        }
        if entry.type == "tree" {
            let child = GitTreeNode(id: entry.sha, isRoot: false)
            node.trees[JSString(name)] = child
            lookup[entryPath] = child
        } else if entry.type == "blob" {
            node.blobs[JSString(name)] = .string(entry.sha)
            blobsShaToPathCache[entry.sha.description] = "/" + entryPath
        } else {
            throw JSONDecodingError("Unknown entry type!!")
        }
    }
    return try ISnapshotTreeEx(json: root.json)
}

/// A node under construction. gitHelper.ts gives subtrees an empty `commits` object; the root has none.
private final class GitTreeNode {
    let id: JSString
    let isRoot: Bool
    var blobs = JSObject<JSONValue>()
    var trees = JSObject<GitTreeNode>()

    init(id: JSString, isRoot: Bool) {
        self.id = id
        self.isRoot = isRoot
    }

    var json: JSONValue {
        var object = JSObject<JSONValue>()
        object["id"] = .string(id)
        object["blobs"] = .object(blobs)
        if !isRoot { object["commits"] = .object(JSObject()) }
        var children = JSObject<JSONValue>()
        for (name, child) in trees.entries { children[name] = child.json }
        object["trees"] = .object(children)
        return .object(object)
    }
}
