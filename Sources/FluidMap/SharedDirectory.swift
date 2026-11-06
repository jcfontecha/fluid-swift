import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// `directory.ts` IDirectoryDataObject, built by reference as serializeDirectory fills it.
private final class IDirectoryDataObject {
  var ci: ICreateInfo?
  var storage: JSObject<JSONValue>?
  var subdirectories: JSObject<IDirectoryDataObject>?

  /// `JSON.stringify` field order: ci, storage, subdirectories.
  var json: JSONValue {
    var object = JSObject<JSONValue>()
    if let ci {
      var createInfo = JSObject<JSONValue>()
      createInfo["csn"] = .number(Double(ci.csn))
      createInfo["ccIds"] = .array(ci.ccIds.map(JSONValue.string))
      object["ci"] = .object(createInfo)
    }
    if let storage {
      object["storage"] = .object(storage)
    }
    if let subdirectories {
      var children = JSObject<JSONValue>()
      for (name, child) in subdirectories.entries {
        children[name] = child.json
      }
      object["subdirectories"] = .object(children)
    }
    return .object(object)
  }
}

/// Port of `packages/dds/map/src/directory.ts` SharedDirectory: the channel, its root
/// SubDirectory, path resolution, op dispatch and summaries.
public final class SharedDirectory: SharedObject<DirectoryLocalOpMetadata> {
  public override class var type: JSString { "https://graph.microsoft.com/types/directory" }

  private static let snapshotFileName: JSString = "header"
  private static let minValueSizeSeparateSnapshotBlob = 8 * 1024
  private static let messageHandlerTypes: [JSString] = [
    "clear", "delete", "set", "createSubDirectory", "deleteSubDirectory",
  ]

  /// "valueChanged" (changed, local).
  public var valueChanged: ((IDirectoryValueChanged, Bool) -> Void)?
  /// "clear" (local).
  public var clearEvent: ((Bool) -> Void)?
  /// "cleared" (path, local).
  public var cleared: ((JSString, Bool) -> Void)?
  /// "containedValueChanged" (changed, local), mirrored from the root.
  public var containedValueChanged: ((IValueChanged, Bool) -> Void)?
  /// "subDirectoryCreated" (relativePath, local), mirrored from the root.
  public var subDirectoryCreated: ((JSString, Bool) -> Void)?
  /// "subDirectoryDeleted" (relativePath, local), mirrored from the root.
  public var subDirectoryDeleted: ((JSString, Bool) -> Void)?

  /// Most operations on the SharedDirectory itself act on the root. Its mirroring listeners are
  /// registered before any other, as in the TS constructor.
  public private(set) lazy var root: SubDirectory = {
    let root = SubDirectory(
      seqData: SequenceData(seq: 0, clientSeq: 0), clientIds: [], directory: self,
      absolutePath: PosixPath.sep)
    root.onContainedValueChanged { [unowned self] changed, local in
      containedValueChanged?(changed, local)
    }
    root.onSubDirectoryCreated { [unowned self] relativePath, local in
      subDirectoryCreated?(relativePath, local)
    }
    root.onSubDirectoryDeleted { [unowned self] relativePath, local in
      subDirectoryDeleted?(relativePath, local)
    }
    return root
  }()

  func emitValueChanged(_ changed: IDirectoryValueChanged, _ local: Bool) {
    valueChanged?(changed, local)
  }

  func emitClear(_ local: Bool) {
    clearEvent?(local)
  }

  func emitCleared(_ path: JSString, _ local: Bool) {
    cleared?(path, local)
  }

  public var absolutePath: JSString { root.absolutePath }

  public func get(_ key: JSString) -> JSONValue? {
    root.get(key)
  }

  public func set(_ key: JSString, _ value: JSONValue?) throws {
    try root.set(key, value)
  }

  @discardableResult
  public func delete(_ key: JSString) throws -> Bool {
    try root.delete(key)
  }

  public func clear() throws {
    try root.clear()
  }

  public func has(_ key: JSString) throws -> Bool {
    try root.has(key)
  }

  public func entries() throws -> [(JSString, JSONValue?)] {
    try root.entries()
  }

  @discardableResult
  public func createSubDirectory(_ subdirName: JSString) throws -> SubDirectory {
    try root.createSubDirectory(subdirName)
  }

  public func getSubDirectory(_ subdirName: JSString) throws -> SubDirectory? {
    try root.getSubDirectory(subdirName)
  }

  @discardableResult
  public func deleteSubDirectory(_ subdirName: JSString) throws -> Bool {
    try root.deleteSubDirectory(subdirName)
  }

  public func subdirectories() throws -> [(JSString, SubDirectory)] {
    try root.subdirectories()
  }

  /// Resolves against the root through optimistic children.
  public func getWorkingDirectory(_ relativePath: JSString) throws -> SubDirectory? {
    let absolutePath = makeAbsolute(relativePath)
    if absolutePath == PosixPath.sep {
      return root
    }
    var currentSubDir = root
    for subdir in Self.pathComponents(absolutePath) {
      guard let next = try currentSubDir.getSubDirectory(subdir) else {
        return nil
      }
      currentSubDir = next
    }
    return currentSubDir
  }

  /// Like getWorkingDirectory, through sequenced children only: ops are only processed on
  /// sequenced directories, so they never apply to a pending one out of order.
  private func getSequencedWorkingDirectory(_ relativePath: JSString) throws -> SubDirectory? {
    let absolutePath = makeAbsolute(relativePath)
    if absolutePath == PosixPath.sep {
      return root
    }
    var currentSubDir = root
    for subdir in Self.pathComponents(absolutePath) {
      guard let next = try currentSubDir.sequencedSubdirectories().get(subdir) else {
        return nil
      }
      currentSubDir = next
    }
    return currentSubDir
  }

  /// `absolutePath.slice(1).split(posix.sep)`.
  private static func pathComponents(_ absolutePath: JSString) -> [JSString] {
    absolutePath.utf16.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false).map {
      JSString(utf16: ContiguousArray($0))
    }
  }

  private func makeAbsolute(_ relativePath: JSString) -> JSString {
    PosixPath.resolve(PosixPath.sep, relativePath)
  }

  func submitDirectoryMessage(_ op: JSONValue, _ localOpMetadata: DirectoryLocalOpMetadata) throws {
    try submitLocalMessage(op, localOpMetadata)
  }

  public override func summarize() -> SummaryTree {
    do {
      return try serializeDirectory()
    } catch {
      // Only a disposed root can fail, and the root is never disposed.
      preconditionFailure("directory summarize failed: \(error)")
    }
  }

  /// `serializeDirectory`: LIFO traversal. Each node gets ci, then sequenced storage (large values
  /// go to their own blob, as a sparse path chain), then optimistic children in creation order.
  private func serializeDirectory() throws -> SummaryTree {
    var tree = JSObject<SummaryObject>()
    var counter = 0
    var blobs: [JSONValue] = []

    let content = IDirectoryDataObject()
    var stack: [(SubDirectory, IDirectoryDataObject)] = [(root, content)]
    while let (currentSubDir, currentSubDirObject) = stack.popLast() {
      currentSubDirObject.ci = try currentSubDir.getSerializableCreateInfo()
      for (key, value) in try currentSubDir.getSerializedStorage() {
        if currentSubDirObject.storage == nil {
          currentSubDirObject.storage = JSObject()
        }
        var result = JSObject<JSONValue>()
        result["type"] = .string(value.type)
        result["value"] = value.parsed
        if let text = value.value, text.length >= Self.minValueSizeSeparateSnapshotBlob {
          // Computed-property literals: `__proto__` is an own property here.
          var largeStorage = JSObject<JSONValue>()
          largeStorage[key] = .object(result)
          var largeContent = JSObject<JSONValue>()
          largeContent["storage"] = .object(largeStorage)
          var extraContent = JSONValue.object(largeContent)
          if currentSubDir.absolutePath != PosixPath.sep {
            for dir in Self.pathComponents(currentSubDir.absolutePath).reversed() {
              var child = JSObject<JSONValue>()
              child[dir] = extraContent
              var parent = JSObject<JSONValue>()
              parent["subdirectories"] = .object(child)
              extraContent = .object(parent)
            }
          }
          let blobName = JSString("blob\(counter)")
          counter += 1
          blobs.append(.string(blobName))
          tree[blobName] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(extraContent)))))
        } else if key != "__proto__" {
          // Assigning `__proto__` on a plain object sets its prototype; no own property results.
          currentSubDirObject.storage?[key] = .object(result)
        }
      }

      for (subdirName, subdir) in try currentSubDir.subdirectories() {
        if currentSubDirObject.subdirectories == nil {
          currentSubDirObject.subdirectories = JSObject()
        }
        let subDataObject = IDirectoryDataObject()
        if subdirName != "__proto__" {
          currentSubDirObject.subdirectories?[subdirName] = subDataObject
        }
        stack.append((subdir, subDataObject))
      }
    }

    var newFormat = JSObject<JSONValue>()
    newFormat["blobs"] = .array(blobs)
    newFormat["content"] = content.json
    tree[Self.snapshotFileName] = .blob(
      ISummaryBlob(content: .text(JSString(JSON.stringify(.object(newFormat))))))
    return SummaryTree(tree: tree)
  }

  /// `loadCore`: new format populates content then the listed blobs in order; otherwise the
  /// header is the old root object.
  public override func loadCore(_ summary: SummaryTree) throws {
    let data = try summary.readAndParse(Self.snapshotFileName)
    guard case .array(let blobNames) = try data.asObject()["blobs"] else {
      try populate(data)
      return
    }
    try populate(data.member("content"))
    for blobName in blobNames {
      try populate(summary.readAndParse(blobName.asString()))
    }
  }

  /// `populate`: LIFO; children are created (in `Object.entries` order) before the node's own
  /// storage is written. Existing children are reused for sparse blobs.
  private func populate(_ data: JSONValue) throws {
    var stack: [(SubDirectory, JSONValue)] = [(root, data)]
    while let (currentSubDir, currentSubDirObject) = stack.popLast() {
      let object = try currentSubDirObject.asObject()
      if let subdirectories = object["subdirectories"] {
        // seq -> next fake clientSeq for children created by this node.
        var tempSeqNums: [Int: Int] = [:]
        for (subdirName, subdirObject) in try subdirectories.asObject().entries {
          if let existing = try currentSubDir.getSubDirectory(subdirName) {
            stack.append((existing, subdirObject))
            continue
          }
          let createInfo = try subdirObject.asObject()["ci"].map { try parseCreateInfo($0) }
          let seqData: SequenceData
          if let createInfo, createInfo.csn > 0 {
            // Only the load order matters, so a fake clientSeq suffices.
            let fakeClientSeq = tempSeqNums[createInfo.csn] ?? 0
            seqData = SequenceData(seq: createInfo.csn, clientSeq: fakeClientSeq)
            tempSeqNums[createInfo.csn] = fakeClientSeq + 1
          } else {
            // csn -1 loads as 0, or ops would never apply; -1 and 0 share one counter.
            currentSubDir.localCreationSeq += 1
            seqData = SequenceData(seq: 0, clientSeq: currentSubDir.localCreationSeq)
          }
          let newSubDir = SubDirectory(
            seqData: seqData, clientIds: createInfo?.ccIds ?? [], directory: self,
            absolutePath: PosixPath.join(currentSubDir.absolutePath, subdirName))
          try currentSubDir.populateSubDirectory(subdirName, newSubDir)
          stack.append((newSubDir, subdirObject))
        }
      }
      if let storage = object["storage"] {
        for (key, serializable) in try storage.asObject().entries {
          try currentSubDir.populateStorage(key, parseSerializableValue(serializable))
        }
      }
    }
  }

  private func parseCreateInfo(_ json: JSONValue) throws -> ICreateInfo {
    ICreateInfo(
      csn: try json.member("csn").asInt(),
      ccIds: try json.member("ccIds").asArray().map { try $0.asString() })
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents where content.message.type == MessageType.operation {
      try processMessage(content.message, local: local, localOpMetadata: content.metadata)
    }
  }

  /// The message handlers' `process`: resolve the target among sequenced directories and skip a
  /// missing or disposed one.
  private func processMessage(
    _ message: SequencedMessage, local: Bool, localOpMetadata: DirectoryLocalOpMetadata?
  ) throws {
    let op = message.contents
    let type = try op.member("type").asString()
    guard Self.messageHandlerTypes.contains(type) else {
      throw SharedObjectError("0x00e: Missing message handler for message type")
    }
    let path = try op.member("path").asString()
    guard let subdir = try getSequencedWorkingDirectory(path), !subdir.disposed else {
      return
    }
    switch type {
    case "clear":
      var pendingClear: SubDirectory.PendingClear?
      if case .clear(let metadata) = localOpMetadata {
        pendingClear = metadata
      }
      try subdir.processClearMessage(message, local: local, localOpMetadata: pendingClear)
    case "delete":
      try subdir.processDeleteMessage(
        message, key: op.member("key").asString(), local: local, localOpMetadata: localOpMetadata)
    case "set":
      // A local set's value comes from its pending entry, not from the op.
      let value = local ? nil : try parseSerializableValue(op.member("value"))
      try subdir.processSetMessage(
        message, key: op.member("key").asString(), value: value, local: local,
        localOpMetadata: localOpMetadata)
    case "createSubDirectory":
      try subdir.processCreateSubDirectoryMessage(
        message, subdirName: op.member("subdirName").asString(), local: local,
        localOpMetadata: localOpMetadata, clientSequenceNumber: message.clientSequenceNumber)
    case "deleteSubDirectory":
      try subdir.processDeleteSubDirectoryMessage(
        message, subdirName: op.member("subdirName").asString(), local: local,
        localOpMetadata: localOpMetadata)
    default:
      throw SharedObjectError("0x00e: Missing message handler for message type")
    }
  }

  /// The message handlers' `resubmit`: the metadata names the original target; a disposed one
  /// drops the op.
  public override func reSubmitCore(
    _ content: JSONValue, localOpMetadata: DirectoryLocalOpMetadata
  ) throws {
    switch localOpMetadata {
    case .clear(let pendingClear):
      if !pendingClear.subdir.disposed {
        try pendingClear.subdir.resubmitClearMessage(content, pendingClear)
      }
    case .set(let pendingKeySet):
      if !pendingKeySet.subdir.disposed {
        try pendingKeySet.subdir.resubmitKeyMessage(content, localOpMetadata)
      }
    case .delete(let pendingKeyDelete):
      if !pendingKeyDelete.subdir.disposed {
        try pendingKeyDelete.subdir.resubmitKeyMessage(content, localOpMetadata)
      }
    case .createSubDir(let parentSubdir), .deleteSubDir(_, let parentSubdir):
      if !parentSubdir.disposed {
        try parentSubdir.resubmitSubDirectoryMessage(content, localOpMetadata)
      }
    }
  }

  public override func rollback(
    _ content: JSONValue, localOpMetadata: DirectoryLocalOpMetadata
  ) throws {
    if let subdir = try getWorkingDirectory(content.member("path").asString()) {
      try subdir.rollback(content, localOpMetadata)
    }
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    let dir = try getWorkingDirectory(content.member("path").asString())
    switch try content.member("type").asString() {
    case "clear":
      try dir?.clear()
    case "createSubDirectory":
      try dir?.createSubDirectory(content.member("subdirName").asString())
    case "delete":
      try dir?.delete(content.member("key").asString())
    case "deleteSubDirectory":
      try dir?.deleteSubDirectory(content.member("subdirName").asString())
    case "set":
      try dir?.set(content.member("key").asString(), parseSerializableValue(content.member("value")))
    default:
      throw SharedObjectError("unknown directory stashed op")
    }
  }
}
