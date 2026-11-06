import FluidDriverDefinitions
import FluidJS
// The public API exposes `FluidValue` and `FluidSerializer`, so clients need them too.
@_exported import FluidSharedObjectBase

/// A local write awaiting its ACK or rollback. TS keeps the write's Promise listeners and the in-memory
/// op; here `value` is that in-memory value, which the ACK applies, and `onSettled` is the Promise.
private struct PendingWrite {
  let value: FluidValue
  let onSettled: ((Bool) -> Void)?
}

/// A per-key register collection with a consensus atomic winner and a version list.
/// Port of `packages/dds/register-collection/src/consensusRegisterCollection.ts` ConsensusRegisterCollection.
/// The TS factory (`consensusRegisterCollectionFactory.ts`) is carried by the `Channel` conformance:
/// `type`, `init(id:)` and `load(id:summary:)`.
public final class ConsensusRegisterCollection: SharedObject<Int> {
  public override class var type: JSString { "https://graph.microsoft.com/types/consensus-register-collection" }

  private static let snapshotFileName: JSString = "header"

  private let serializer = FluidSerializer()

  /// `data`: one entry per key, in first-insertion order (a JS `Map`).
  private var data = JSMap<JSString, ILocalData>()

  /// `nextPendingMessageId`: the ID of the next local write submitted.
  private var nextPendingMessageId = 0

  /// Local writes submitted and not yet ACKed or rolled back, by pending message ID.
  private var pendingWrites: [Int: PendingWrite] = [:]

  /// "atomicChanged" (key, value, local). Emitted only when the write won the atomic register.
  public var atomicChanged: ((JSString, FluidValue, Bool) -> Void)?

  /// "versionChanged" (key, value, local). Emitted for every write, winner or not.
  public var versionChanged: ((JSString, FluidValue, Bool) -> Void)?

  /// `write`: creates a register or writes a new value. `onSettled` is the Promise<boolean>: it receives
  /// `true` when the write won, and `false` when it lost or was rolled back. A detached write is applied
  /// at once and settles `true`.
  public func write(_ key: JSString, _ value: FluidValue, onSettled: ((Bool) -> Void)? = nil) throws {
    try verifyOpen()
    guard isAttached else {
      try processInboundWrite(key, value, refSeq: 0, sequenceNumber: 0, local: true)
      onSettled?(true)
      return
    }
    // The ref seq is captured at creation and rides in the op, so a resubmit keeps it.
    let refSeq = try currentReferenceSequenceNumber()
    let messageId = nextPendingMessageId
    nextPendingMessageId += 1
    pendingWrites[messageId] = PendingWrite(value: value, onSettled: onSettled)
    try submitLocalMessage(writeOp(key, value, refSeq: refSeq), messageId)
  }

  /// `read`: the agreed value for a key under `policy`. Undefined for an absent key.
  public func read(_ key: JSString, _ policy: ReadPolicy = .atomic) throws -> FluidValue {
    if policy == .atomic {
      return readAtomic(key)
    }
    guard let versions = readVersions(key) else {
      return .undefined
    }
    // We don't support deletion. So there should be at least one value.
    guard let latest = versions.last else {
      throw SharedObjectError("0x06c: Value should be undefined or non-empty")
    }
    return latest
  }

  /// `readVersions`: every concurrent version of a key, or nil for an absent key.
  public func readVersions(_ key: JSString) -> [FluidValue]? {
    data.get(key)?.versions.map(\.value)
  }

  /// `keys`: the keys in live insertion order.
  public func keys() -> [JSString] {
    data.keys
  }

  /// `summarizeCore`: a single `header` blob holding a plain object of every key. Assigning `__proto__` on
  /// a plain object sets its prototype rather than a property, so that key never reaches the summary.
  public override func summarize() -> SummaryTree {
    var content = JSObject<FluidValue>()
    for (key, entry) in data.entries where key != "__proto__" {
      content[key] = Self.encodeData(entry)
    }
    return .singleBlob(Self.snapshotFileName, JSString(serializer.stringify(.object(content))))
  }

  /// `loadCore`: each key is stored as the summary holds it, with no versions recomputed and no events.
  public override func loadCore(_ summary: SummaryTree) throws {
    let header = try summary.readAndParse(Self.snapshotFileName).asObject()
    for (key, entry) in header.entries {
      data.set(key, try decodeData(entry))
    }
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local, localOpMetadata: content.metadata)
    }
  }

  /// `processMessage`: a remote write is applied from its op. A local write is applied with the in-memory
  /// value it was submitted with, then its pending write settles with the winner flag.
  private func processMessage(_ message: SequencedMessage, local: Bool, localOpMetadata: Int?) throws {
    guard message.type == MessageType.operation else {
      return
    }
    let op = message.contents
    guard try op.member("type").asString() == "write" else {
      throw SharedObjectError("unreachable: unknown register operation")
    }
    let key = try op.member("key").asString()
    let refSeq = try refSeqWhenCreated(op, message)
    guard refSeq <= message.referenceSequenceNumber else {
      throw SharedObjectError("0x06e: Message's reference sequence number < op's reference sequence number!")
    }
    guard local else {
      let value = try incomingValue(op)
      try processInboundWrite(key, value, refSeq: refSeq, sequenceNumber: message.sequenceNumber, local: false)
      return
    }
    guard let messageId = localOpMetadata else {
      throw SharedObjectError("0xc0e: Expect localOpMetadata to be a number")
    }
    guard let pendingWrite = pendingWrites.removeValue(forKey: messageId) else {
      throw SharedObjectError("0xc0e: no pending write for local acknowledgement \(messageId)")
    }
    let isWinner = try processInboundWrite(
      key, pendingWrite.value, refSeq: refSeq, sequenceNumber: message.sequenceNumber, local: true)
    pendingWrite.onSettled?(isWinner)
  }

  /// `processInboundWrite`: the write takes the atomic register when the key is new or its refSeq covers
  /// the current atomic write. Versions the writer had already seen are dropped from the front, then this
  /// write is appended. Returns whether it won.
  @discardableResult
  private func processInboundWrite(
    _ key: JSString, _ value: FluidValue, refSeq: Int, sequenceNumber: Int, local: Bool
  ) throws -> Bool {
    let isWinner: Bool
    var entry: ILocalData
    if let existing = data.get(key) {
      isWinner = refSeq >= existing.atomic.sequenceNumber
      entry = existing
      if isWinner {
        entry.atomic = ILocalRegister(sequenceNumber: sequenceNumber, value: value)
      }
    } else {
      isWinner = true
      entry = ILocalData(
        atomic: ILocalRegister(sequenceNumber: sequenceNumber, value: value), versions: [])
    }

    // Remove the versions that were known to the remote client at the time of the write.
    let shadowed = entry.versions.prefix(while: { refSeq >= $0.sequenceNumber }).count
    entry.versions.removeFirst(shadowed)

    // Asserts for data integrity. A key that does not exist yet always wins, so the loser path always
    // has data here, and TS's 0x06f assert cannot fail.
    if !isAttached {
      guard refSeq == 0 && sequenceNumber == 0 else {
        throw SharedObjectError("0x070: sequence numbers are expected to be 0 when unattached")
      }
    } else if let last = entry.versions.last {
      // seqNum should always be increasing, except for the case of grouped batches (seqNum will be the same)
      guard sequenceNumber >= last.sequenceNumber else {
        throw SharedObjectError("0x071: Versions should naturally be ordered by sequenceNumber")
      }
    }

    entry.versions.append(ILocalRegister(sequenceNumber: sequenceNumber, value: value))
    data.set(key, entry)

    // Raise events at the end, to avoid reentrancy issues.
    if isWinner {
      atomicChanged?(key, value, local)
    }
    versionChanged?(key, value, local)
    return isWinner
  }

  /// `rollback`: the write was never applied locally, so nothing is undone. Its Promise resolves false.
  public override func rollback(_ content: JSONValue, localOpMetadata: Int) throws {
    pendingWrites.removeValue(forKey: localOpMetadata)?.onSettled?(false)
  }

  /// `applyStashedOp`: submits the stashed write as it was created, so its ACK can match. A stashed write
  /// has no Promise and changes no local value until it is sequenced.
  public override func applyStashedOp(_ content: JSONValue) throws {
    guard try content.member("type").asString() == "write" else {
      throw SharedObjectError("0xccc: Only write ops should be stashed")
    }
    let messageId = nextPendingMessageId
    nextPendingMessageId += 1
    pendingWrites[messageId] = PendingWrite(value: try incomingValue(content), onSettled: nil)
    try submitLocalMessage(content, messageId)
  }

  private func readAtomic(_ key: JSString) -> FluidValue {
    data.get(key)?.atomic.value ?? .undefined
  }

  /// `this.deltaManager.lastSequenceNumber`, the refSeq a write captures.
  private func currentReferenceSequenceNumber() throws -> Int {
    guard let runtime else {
      throw SharedObjectError("ConsensusRegisterCollection is attached but has no runtime")
    }
    return runtime.deltaManager.lastSequenceNumber
  }

  /// The refSeq captured when the op was created. A legacy op without one takes the envelope's.
  private func refSeqWhenCreated(_ op: JSONValue, _ message: SequencedMessage) throws -> Int {
    guard let refSeq = try op.asObject()["refSeq"] else {
      return message.referenceSequenceNumber
    }
    return try refSeq.asInt()
  }

  /// The value a remote op carries, as TS reads it. A `value` member is used as is (not decoded, so a
  /// handle-shaped object stays plain data). Without one, `serializedValue` is parsed, which decodes handles.
  private func incomingValue(_ op: JSONValue) throws -> FluidValue {
    guard let wrapper = try op.asObject()["value"] else {
      return try serializer.parse(try op.member("serializedValue").asString().description)
    }
    guard let inner = try wrapper.asObject()["value"] else {
      return .undefined
    }
    return .json(inner)
  }

  /// The write op, in TS key order: key, type, serializedValue, value, refSeq. An undefined value has no
  /// serializedValue, because `JSON.stringify(undefined)` yields none.
  private func writeOp(_ key: JSString, _ value: FluidValue, refSeq: Int) -> JSONValue {
    var wrapper = JSObject<FluidValue>()
    wrapper["type"] = .json(.string("Plain"))
    wrapper["value"] = value
    var op = JSObject<FluidValue>()
    op["key"] = .json(.string(key))
    op["type"] = .json(.string("write"))
    if value != .undefined {
      op["serializedValue"] = .json(.string(JSString(serializer.stringify(value))))
    }
    op["value"] = .object(wrapper)
    op["refSeq"] = .json(.number(Double(refSeq)))
    return serializer.encode(.object(op))
  }

  private static func encodeRegister(_ register: ILocalRegister) -> FluidValue {
    var wrapper = JSObject<FluidValue>()
    wrapper["type"] = .json(.string("Plain"))
    wrapper["value"] = register.value
    var object = JSObject<FluidValue>()
    object["sequenceNumber"] = .json(.number(Double(register.sequenceNumber)))
    object["value"] = .object(wrapper)
    return .object(object)
  }

  private static func encodeData(_ data: ILocalData) -> FluidValue {
    var object = JSObject<FluidValue>()
    object["atomic"] = encodeRegister(data.atomic)
    object["versions"] = .array(data.versions.map(encodeRegister))
    return .object(object)
  }

  /// One key's summary entry. A `Shared` atomic value is rejected (0x06d), as TS does.
  private func decodeData(_ json: JSONValue) throws -> ILocalData {
    let atomic = try json.member("atomic")
    guard try atomic.member("value").member("type") != .string("Shared") else {
      throw SharedObjectError(
        "0x06d: SharedObjects contained in ConsensusRegisterCollection can no longer be deserialized as of 0.17")
    }
    let versions = try json.member("versions").asArray().map { try decodeRegister($0) }
    return ILocalData(atomic: try decodeRegister(atomic), versions: versions)
  }

  private func decodeRegister(_ json: JSONValue) throws -> ILocalRegister {
    let sequenceNumber = try json.member("sequenceNumber").asInt()
    guard let inner = try json.member("value").asObject()["value"] else {
      return ILocalRegister(sequenceNumber: sequenceNumber, value: .undefined)
    }
    return ILocalRegister(sequenceNumber: sequenceNumber, value: try serializer.decode(inner))
  }
}
