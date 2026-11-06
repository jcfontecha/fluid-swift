import FluidJS

/// Ports blobManager/blobManagerSnapSum.ts persisted snapshot loading and byte-exact summaries.
public struct BlobManagerLoadInfo {
  public var ids: [JSString]
  public var redirectTable: [(JSString, JSString)]
  public init(ids: [JSString] = [], redirectTable: [(JSString, JSString)] = []) {
    self.ids = ids
    self.redirectTable = redirectTable
  }
}
public func toRedirectTable(_ info: BlobManagerLoadInfo) -> JSMap<JSString, JSString> {
  var table = JSMap<JSString, JSString>()
  for (local, storage) in info.redirectTable { table.set(local, storage) }
  for storage in info.ids { table.set(storage, storage) }
  return table
}
public func loadBlobManagerLoadInfo(_ snapshot: JSONValue?, readBlob: (JSString) throws -> String) throws -> BlobManagerLoadInfo {
  guard let snapshot, let blobsTree = try field(snapshot.member("trees"), ".blobs") else { return BlobManagerLoadInfo() }
  let blobs = try blobsTree.member("blobs").asObject()
  var entries: [(JSString, JSString)] = []
  if let tableId = blobs[".redirectTable"], try !tableId.asString().utf16.isEmpty {
    for entry in try JSON.parse(readBlob(tableId.asString())).asArray() {
      let pair = try entry.asArray()
      try require(pair.count == 2, "invalid redirect entry")
      entries.append(try (pair[0].asString(), pair[1].asString()))
    }
  }
  let ids = try blobs.entries.filter { $0.key != ".redirectTable" }.map { try $0.value.asString() }
  return BlobManagerLoadInfo(ids: ids, redirectTable: entries)
}

public func summarizeBlobManagerState(_ redirects: JSMap<JSString, JSString>) -> JSONValue {
  var tree = JSObject<JSONValue>()
  var storageIds: Set<JSString> = []
  for (_, storage) in redirects.entries where storageIds.insert(storage).inserted {
    tree[JSString(String(tree.count))] = object([("id", .string(storage)), ("type", number(4))])
  }
  let entries = redirects.entries.filter { $0.key != $0.value }.map { JSONValue.array([.string($0.key), .string($0.value)]) }
  var size = 0
  if !entries.isEmpty {
    let content = JSON.stringify(.array(entries))
    size = content.utf8.count
    tree[".redirectTable"] = object([("type", number(2)), ("content", string(content))])
  }
  return object([("summary", object([("type", number(1)), ("tree", .object(tree))])), ("stats", object([("treeNodeCount", number(1)), ("blobNodeCount", number(entries.isEmpty ? 0 : 1)), ("handleNodeCount", number(0)), ("totalBlobSize", number(size)), ("unreferencedBlobSize", number(0))]))])
}
