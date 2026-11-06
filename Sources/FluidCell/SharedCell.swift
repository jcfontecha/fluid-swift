import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
// The public API exposes `FluidValue` and `FluidSerializer`, so clients need them too.
import FluidSharedObjectBase

/// Per-op metadata kept for a local `setCell` or `deleteCell` until it is acknowledged or rolled back.
/// Port of `packages/dds/cell/src/interfaces.ts` ICellLocalOpMetadata.
public struct ICellLocalOpMetadata {
  public let pendingMessageId: Int
  public let previousValue: FluidValue
}

/// A single optimistic last-sequenced-writer register.
/// Port of `packages/dds/cell/src/cell.ts` SharedCell.
public final class SharedCell: SharedObject<ICellLocalOpMetadata> {
  public override class var type: JSString { "https://graph.microsoft.com/types/cell" }

  private static let snapshotFileName: JSString = "header"

  private let serializer = FluidSerializer()

  /// `options.attribution.track`: whether this cell records attribution for its changes.
  private let attributionTrack: Bool

  /// The data held by this cell. `.undefined` is JS undefined, which is what an empty cell holds.
  private var data: FluidValue = .undefined

  /// Id of the latest local op, or -1 before any. Ops with an id above `messageIdObserved` are
  /// still awaiting acknowledgement, and remote ops are ignored until none are.
  private var messageId = -1

  /// Id of the latest acknowledged local op.
  private var messageIdObserved = -1

  /// Ids of local ops awaiting acknowledgement, oldest first.
  private var pendingMessageIds: [Int] = []

  /// The attribution JSON as loaded or set, such as `{"type":"op","seq":1}`.
  private var attribution: JSONValue?

  /// "valueChanged" (value). Emitted before attribution is updated.
  public var valueChanged: ((FluidValue) -> Void)?

  /// "delete" (). Emitted even if the cell was already empty.
  public var deleteEvent: (() -> Void)?

  public init(id: JSString, attributionTrack: Bool) {
    self.attributionTrack = attributionTrack
    super.init(id: id)
  }

  public required init(id: JSString) {
    attributionTrack = false
    super.init(id: id)
  }

  public func get() -> FluidValue {
    data
  }

  /// True only for JS undefined. A cell set to `undefined` is empty, but `set` still emits
  /// `valueChanged`, not `delete`.
  public func empty() -> Bool {
    data == .undefined
  }

  public func getAttribution() -> JSONValue? {
    attribution
  }

  public func set(_ value: FluidValue) throws {
    try verifyOpen()
    let previousValue = setCore(value)
    setAttribution()
    // A detached cell keeps its value locally and submits nothing.
    guard isAttached else {
      return
    }
    try submitCellMessage(setOp(value), previousValue)
  }

  public func delete() throws {
    try verifyOpen()
    let previousValue = deleteCore()
    setAttribution()
    guard isAttached else {
      return
    }
    try submitCellMessage(Self.deleteOp(), previousValue)
  }

  /// `summarizeCore`: a single `header` blob `{value, attribution}`. Undefined members are omitted,
  /// and local attribution is never persisted.
  public override func summarize() -> SummaryTree {
    var content = JSObject<FluidValue>()
    content["value"] = data
    if let attribution, !attributionIsLocal {
      content["attribution"] = .json(attribution)
    }
    return .singleBlob(Self.snapshotFileName, JSString(serializer.stringify(.object(content))))
  }

  public override func loadCore(_ summary: SummaryTree) throws {
    let content = try summary.readAndParse(Self.snapshotFileName).asObject()
    if let value = content["value"] {
      data = try serializer.decode(value)
    } else {
      data = .undefined
    }
    attribution = content["attribution"]
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local, localOpMetadata: content.metadata)
    }
  }

  /// `processMessage`. While a local op awaits its ACK, every incoming message is ignored except
  /// that ACK, so a later remote write stays hidden until it is acknowledged. Once no local op is
  /// pending, only remote `op` messages apply.
  private func processMessage(
    _ message: SequencedMessage, local: Bool, localOpMetadata: ICellLocalOpMetadata?
  ) throws {
    if messageId != messageIdObserved {
      if local {
        try acknowledgeLocalOp(message, localOpMetadata)
      }
      return
    }
    guard message.type == MessageType.operation, !local else {
      return
    }
    setAttribution(message)
    try applyInnerOp(message.contents)
  }

  /// The ACK branch of `processMessage`, with asserts 0x00c and 0x471.
  private func acknowledgeLocalOp(
    _ message: SequencedMessage, _ localOpMetadata: ICellLocalOpMetadata?
  ) throws {
    guard let localOpMetadata, localOpMetadata.pendingMessageId <= messageId else {
      throw SharedObjectError("0x00c: messageId is incorrect from the local client's ACK")
    }
    guard pendingMessageIds.first == localOpMetadata.pendingMessageId else {
      throw SharedObjectError("0x471: Unexpected pending message received")
    }
    pendingMessageIds.removeFirst()
    messageIdObserved = localOpMetadata.pendingMessageId
    setAttribution(message)
  }

  /// `applyInnerOp`, for a remote op.
  private func applyInnerOp(_ op: JSONValue) throws {
    switch try op.member("type").asString() {
    case "setCell":
      setCore(try decodeSetValue(op))
    case "deleteCell":
      deleteCore()
    default:
      throw SharedObjectError("Unknown operation")
    }
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    switch try content.member("type").asString() {
    case "deleteCell":
      try delete()
    case "setCell":
      try set(decodeSetValue(content))
    default:
      throw SharedObjectError("Unknown operation")
    }
  }

  /// `rollback`. It restores the value but not attribution or the ID counters, so the ID-gap
  /// suppression can remain after a rollback. Preserve that.
  public override func rollback(
    _ content: JSONValue, localOpMetadata: ICellLocalOpMetadata
  ) throws {
    let object = try content.asObject()
    guard
      object["type"] == .string("setCell") || object["type"] == .string("deleteCell")
    else {
      throw SharedObjectError("Unsupported op for rollback")
    }
    if localOpMetadata.previousValue == .undefined {
      deleteCore()
    } else {
      setCore(localOpMetadata.previousValue)
    }
    guard pendingMessageIds.popLast() == localOpMetadata.pendingMessageId else {
      throw SharedObjectError("Rollback op does not match last pending")
    }
  }

  /// `setCore`: the value changes and `valueChanged` fires. Returns the previous value.
  @discardableResult
  private func setCore(_ value: FluidValue) -> FluidValue {
    let previousLocalValue = data
    data = value
    valueChanged?(value)
    return previousLocalValue
  }

  /// `deleteCore`: the value becomes undefined and `delete` fires. Returns the previous value.
  @discardableResult
  private func deleteCore() -> FluidValue {
    let previousLocalValue = data
    data = .undefined
    deleteEvent?()
    return previousLocalValue
  }

  /// `setAttribution`. An op's attribution is its sequence number. A local change is `local` when
  /// attached and `detached` otherwise, with id 0.
  private func setAttribution(_ message: SequencedMessage? = nil) {
    guard attributionTrack else {
      return
    }
    if let message {
      attribution = Self.attributionKey([
        ("type", .string("op")),
        ("seq", .number(Double(message.sequenceNumber))),
      ])
    } else if isAttached {
      attribution = Self.attributionKey([("type", .string("local"))])
    } else {
      attribution = Self.attributionKey([
        ("type", .string("detached")),
        ("id", .number(0)),
      ])
    }
  }

  /// `{type:"local"}` attribution is not persisted, so a summary omits it.
  private var attributionIsLocal: Bool {
    guard case .object(let object)? = attribution else {
      return false
    }
    return object["type"] == .string("local")
  }

  /// `submitCellMessage` and `createLocalOpMetadata`: the op id is allocated at submit time, after
  /// the local change, as in cell.ts.
  private func submitCellMessage(_ op: JSONValue, _ previousValue: FluidValue) throws {
    messageId += 1
    pendingMessageIds.append(messageId)
    try submitLocalMessage(
      op, ICellLocalOpMetadata(pendingMessageId: messageId, previousValue: previousValue))
  }

  /// `{type:"setCell", value:{value}}`. An undefined value omits its member, as `JSON.stringify`
  /// does, which gives `{}`.
  private func setOp(_ value: FluidValue) -> JSONValue {
    var inner = JSObject<FluidValue>()
    inner["value"] = value
    var op = JSObject<FluidValue>()
    op["type"] = .json(.string("setCell"))
    op["value"] = .object(inner)
    return serializer.encode(.object(op))
  }

  /// `{type:"deleteCell"}`.
  private static func deleteOp() -> JSONValue {
    var op = JSObject<JSONValue>()
    op["type"] = .string("deleteCell")
    return .object(op)
  }

  /// The decoded `content.value.value` of a `setCell` op. An absent member is JS undefined.
  private func decodeSetValue(_ op: JSONValue) throws -> FluidValue {
    guard let value = try op.member("value").asObject()["value"] else {
      return .undefined
    }
    return try serializer.decode(value)
  }

  private static func attributionKey(_ fields: [(JSString, JSONValue)]) -> JSONValue {
    var key = JSObject<JSONValue>()
    for (name, value) in fields {
      key[name] = value
    }
    return .object(key)
  }
}
