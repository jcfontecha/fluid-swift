import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// Port of `packages/dds/map/src/map.ts` SharedMap: the channel around a MapKernel.
public final class SharedMap: SharedObject<PendingLocalOpMetadata> {
  public override class var type: JSString { "https://graph.microsoft.com/types/map" }

  private static let snapshotFileName: JSString = "header"
  /// A single property at least this long (UTF-16 units of its JSON) gets its own blob.
  private static let minValueSizeSeparateSnapshotBlob = 8 * 1024
  /// Target size for blobs holding several properties.
  private static let maxSnapshotBlobSize = 16 * 1024

  private lazy var kernel = MapKernel(
    submitMessage: { [unowned self] op, localOpMetadata in
      try submitLocalMessage(op, localOpMetadata)
    },
    isAttached: { [unowned self] in isAttached })

  /// "valueChanged" (changed, local).
  public var valueChanged: ((IValueChanged, Bool) -> Void)? {
    get { kernel.valueChanged }
    set { kernel.valueChanged = newValue }
  }
  /// "clear" (local).
  public var clearEvent: ((Bool) -> Void)? {
    get { kernel.clearEvent }
    set { kernel.clearEvent = newValue }
  }

  public var size: Int { kernel.size }

  public func entries() -> [(JSString, JSONValue?)] {
    kernel.entries()
  }

  public func keys() -> [JSString] {
    kernel.keys()
  }

  public func get(_ key: JSString) -> JSONValue? {
    kernel.get(key)
  }

  public func has(_ key: JSString) -> Bool {
    kernel.has(key)
  }

  public func set(_ key: JSString, _ value: JSONValue?) throws {
    try kernel.set(key, value)
  }

  @discardableResult
  public func delete(_ key: JSString) throws -> Bool {
    try kernel.delete(key)
  }

  public func clear() throws {
    try kernel.clear()
  }

  /// `summarizeCore`: large properties get their own blob; the rest fill blobs of roughly
  /// maxSnapshotBlobSize, then the header holds the remainder. Partitioning is not stable.
  public override func summarize() -> SummaryTree {
    var currentSize = 0
    var counter = 0
    var headerBlob = JSObject<JSONValue>()
    var blobs: [JSONValue] = []
    var tree = JSObject<SummaryObject>()

    let data = kernel.getSerializedStorage()
    for (key, value) in data.orderedEntries {
      let length = value.valueLength
      if length >= Self.minValueSizeSeparateSnapshotBlob {
        let blobName = JSString("blob\(counter)")
        counter += 1
        blobs.append(.string(blobName))
        var content = JSObject<JSONValue>()
        content[key] = serializable(value)
        tree[blobName] = blob(.object(content))
      } else {
        // Approximate cost of the property header; the key length is not counted.
        currentSize += value.type.length + 21
        currentSize += length
        if currentSize > Self.maxSnapshotBlobSize {
          let blobName = JSString("blob\(counter)")
          counter += 1
          blobs.append(.string(blobName))
          tree[blobName] = blob(.object(headerBlob))
          headerBlob = JSObject()
          currentSize = 0
        }
        headerBlob[key] = serializable(value)
      }
    }

    var header = JSObject<JSONValue>()
    header["blobs"] = .array(blobs)
    header["content"] = .object(headerBlob)
    tree[Self.snapshotFileName] = blob(.object(header))
    return SummaryTree(tree: tree)
  }

  /// `{type, value: JSON.parse(value.value)}`.
  private func serializable(_ value: ISerializedValue) -> JSONValue {
    var result = JSObject<JSONValue>()
    result[typeMember] = .string(value.type)
    result[valueMember] = value.parsed
    return .object(result)
  }

  private func blob(_ content: JSONValue) -> SummaryObject {
    .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(content)))))
  }

  /// `loadCore`: the header content first, then the listed blobs in list order. A header without a
  /// `blobs` array is the old unwrapped format.
  public override func loadCore(_ summary: SummaryTree) throws {
    let json = try summary.readAndParse(Self.snapshotFileName)
    guard case .array(let blobNames) = try json.asObject()["blobs"] else {
      try kernel.populateFromSerializable(json)
      return
    }
    try kernel.populateFromSerializable(json.member("content"))
    for blobName in blobNames {
      try kernel.populateFromSerializable(summary.readAndParse(blobName.asString()))
    }
  }

  public override func reSubmitCore(
    _ content: JSONValue, localOpMetadata: PendingLocalOpMetadata
  ) throws {
    try kernel.tryResubmitMessage(content, localOpMetadata)
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    try kernel.tryApplyStashedOp(content)
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents where content.message.type == MessageType.operation {
      try kernel.tryProcessMessage(
        content.message.contents, local: local, localOpMetadata: content.metadata)
    }
  }

  public override func rollback(
    _ content: JSONValue, localOpMetadata: PendingLocalOpMetadata
  ) throws {
    try kernel.rollback(content, localOpMetadata)
  }
}
