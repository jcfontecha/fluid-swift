import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// Port of `@fluidframework/counter` `SharedCounter` (counter.ts).
public final class SharedCounter: SharedObject<Int> {
  public override class var type: JSString { "https://graph.microsoft.com/types/counter" }

  private static let snapshotFileName: JSString = "header"

  public struct IncrementError: Error, CustomStringConvertible {
    public let description = "Must increment by a whole number"
  }

  public private(set) var value: Double = 0

  private var pendingOps: [(incrementAmount: Double, messageId: Int)] = []
  private var nextPendingMessageId = 0

  public override func loadCore(_ summary: SummaryTree) throws {
    value = try summary.readAndParse(Self.snapshotFileName).member("value").asNumber()
  }

  /// "incremented" (incrementAmount, newValue).
  public var incremented: ((Double, Double) -> Void)?

  public func increment(_ incrementAmount: Double) throws {
    try verifyOpen()
    // Incrementing by non-integers would be eventually inconsistent, since the order in which
    // increments apply would affect the result.
    guard incrementAmount.truncatingRemainder(dividingBy: 1) == 0 else {
      throw IncrementError()
    }
    let messageId = nextPendingMessageId
    nextPendingMessageId += 1
    incrementCore(incrementAmount)
    // We don't need to send the op if we are not attached yet.
    if isAttached {
      pendingOps.append((incrementAmount, messageId))
      try submitLocalMessage(Self.incrementOp(incrementAmount), messageId)
    }
  }

  private func incrementCore(_ incrementAmount: Double) {
    value += incrementAmount
    incremented?(incrementAmount, value)
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local, localOpMetadata: content.metadata)
    }
  }

  private func processMessage(
    _ message: SequencedMessage, local: Bool, localOpMetadata: Int?
  ) throws {
    guard message.type == MessageType.operation else {
      return
    }
    let op = message.contents
    // A local op was applied optimistically; retire its pending entry instead.
    if local {
      let pendingOp = pendingOps.isEmpty ? nil : pendingOps.removeFirst()
      guard let messageId = localOpMetadata else {
        throw SharedObjectError("0xc8e: localOpMetadata should be a number")
      }
      guard let pendingOp, pendingOp.messageId == messageId,
        try op.member("type").asString() == "increment",
        try pendingOp.incrementAmount == op.member("incrementAmount").asNumber()
      else {
        throw SharedObjectError("0xc8f: local op mismatch")
      }
      return
    }
    switch try op.member("type").asString() {
    case "increment":
      incrementCore(try op.member("incrementAmount").asNumber())
    default:
      throw SharedObjectError("Unknown operation")
    }
  }

  public override func summarize() -> SummaryTree {
    var content = JSObject<JSONValue>()
    content["value"] = .number(value)
    return .singleBlob(Self.snapshotFileName, JSString(JSON.stringify(.object(content))))
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    guard try content.member("type").asString() == "increment" else {
      throw SharedObjectError("0x3ec: Op type is not increment")
    }
    try increment(content.member("incrementAmount").asNumber())
  }

  public override func rollback(_ content: JSONValue, localOpMetadata: Int) throws {
    guard try content.member("type").asString() == "increment" else {
      throw SharedObjectError("0xc92: invalid increment op format")
    }
    let incrementAmount = try content.member("incrementAmount").asNumber()
    guard let pendingOp = pendingOps.popLast(), pendingOp.messageId == localOpMetadata,
      pendingOp.incrementAmount == incrementAmount
    else {
      throw SharedObjectError("0xc91: op to rollback mismatch with pending op")
    }
    // Incrementing by the opposite amount also emits an "incremented" event.
    incrementCore(-incrementAmount)
  }

  private static func incrementOp(_ incrementAmount: Double) -> JSONValue {
    var op = JSObject<JSONValue>()
    op["type"] = .string("increment")
    op["incrementAmount"] = .number(incrementAmount)
    return .object(op)
  }
}
