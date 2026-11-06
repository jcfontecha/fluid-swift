import FluidJS
import FluidDriverDefinitions

/// Ports channelStorageService.ts. The host resolves storage I/O before entering the serial executor.
public final class ChannelStorageService {
    private let tree: SummaryTree
    public init(_ tree: SummaryTree) { self.tree = tree }
    public func contains(_ path: JSString) throws -> Bool { try lookup(path) != nil }
    public func readBlob(_ path: JSString) throws -> JSString {
        guard let value = try lookup(path), case .blob(let blob) = value else {
            throw DatastoreError("0x9d7: blob not found")
        }
        return try blob.json.member("content").asString()
    }
    private func lookup(_ path: JSString) throws -> SummaryObject? {
        var current = try SummaryObject(json: tree.json)
        var parts: [JSString] = []
        var units = ContiguousArray<UInt16>()
        for unit in path.utf16 {
            if unit == 47 {
                parts.append(JSString(utf16: units))
                units.removeAll(keepingCapacity: true)
            } else { units.append(unit) }
        }
        parts.append(JSString(utf16: units))
        for part in parts {
            guard case .tree(let subtree) = current, let value = subtree.tree[part] else { return nil }
            current = value
        }
        return current
    }
}

extension ChannelStorageService {
    public func list(_ path: JSString) throws -> [JSString] {
        if path.length == 0 || path == "/" {
            guard case .tree(let summary) = tree else { throw DatastoreError("path does not exist") }
            return summary.tree.entries.compactMap { key, value in
                if case .blob = value { return key }
                return nil
            }
        }
        var normalized = path.utf16
        while normalized.first == 47 { normalized.removeFirst() }
        while normalized.last == 47 { normalized.removeLast() }
        guard let value = try lookup(JSString(utf16: normalized)), case .tree(let subtree) = value else {
            throw DatastoreError("path does not exist")
        }
        return subtree.tree.entries.compactMap { key, value in
            if case .blob = value { return key }
            return nil
        }
    }
}
