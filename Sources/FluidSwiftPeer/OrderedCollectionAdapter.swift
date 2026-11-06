import CryptoKit
import FluidDriverDefinitions
import FluidJS
import FluidOrderedCollection
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Foundation

// Ordered-collection adapter, as `harness/src/dds.ts` createAdapter defines it for `ordered-collection`.

/// The UUIDs of one harness request, as `harness/src/entropy.ts` produces them. TS replaces `crypto.randomUUID`,
/// which `uuid()` calls, with `sha256("<context>:<draw>")` formatted as a v4 UUID. The context is the client, the
/// ordinal of this call for that client and method, and the method. `draw` counts the UUIDs in the request.
final class HarnessEntropy {
  private let clientId: String
  private var editCount = 0
  private var context = ""
  private var draw = 0

  init(clientId: JSString) {
    self.clientId = clientId.description
  }

  /// Called before each `edit` request, as `setEntropyContext` is.
  func beginEdit() {
    context = "\(clientId):\(editCount):edit"
    editCount += 1
    draw = 0
  }

  func nextUUID() -> JSString {
    let uuid = harnessUUID("\(context):\(draw)")
    draw += 1
    return uuid
  }
}

/// `entropy.ts`: the first 16 bytes of the SHA-256 digest, with the version and variant bits set, as hex in the
/// 8-4-4-4-12 layout.
private func harnessUUID(_ input: String) -> JSString {
  var bytes = Array(SHA256.hash(data: Data(input.utf8)))
  bytes[6] = (bytes[6] & 15) | 64
  bytes[8] = (bytes[8] & 63) | 128
  let hex = Array(bytes.prefix(16).map(hexByte).joined())
  let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
  return JSString(groups.map { String(hex[$0]) }.joined(separator: "-"))
}

private func hexByte(_ byte: UInt8) -> String {
  let digits = Array("0123456789abcdef")
  return String([digits[Int(byte >> 4)], digits[Int(byte & 15)]])
}

/// `state`: `{available: header blob, acquired: jobTracking blob sorted by acquire ID}`. Both blobs are read
/// from the DDS's own summary. The sort is by UTF-16 code units, which equals TS `localeCompare` on the
/// lowercase hex UUIDs the harness generates.
private func orderedCollectionState(_ c: ConsensusQueue) throws -> JSONValue {
  let summary = c.summarize()
  let available = try summary.readAndParse("header")
  var acquired: [(id: JSString, entry: JSONValue)] = []
  for entry in try summary.readAndParse("jobTracking").asArray() {
    guard let first = try entry.asArray().first else {
      throw PeerError(description: "malformed jobTracking entry")
    }
    acquired.append((try first.asString(), entry))
  }
  acquired.sort { $0.id.utf16.lexicographicallyPrecedes($1.id.utf16) }
  var state = JSObject<JSONValue>()
  state["available"] = available
  state["acquired"] = .array(acquired.map(\.entry))
  return .object(state)
}

/// An optional acquire client ID as the event journal writes it: `undefined` in an array is null.
private func clientIdJSON(_ clientId: JSString?) -> JSONValue {
  guard let clientId else {
    return .null
  }
  return .string(clientId)
}

func orderedCollectionAdapter(
  _ runtime: MockContainerRuntime<ConsensusQueue>, clientId: JSString
) -> RuntimeClient<ConsensusQueue> {
  let serializer = FluidSerializer()
  let entropy = HarnessEntropy(clientId: clientId)
  runtime.channel.generateAcquireId = { entropy.nextUUID() }
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      entropy.beginEdit()
      switch try e.member("kind").asString() {
      case "add":
        try c.add(.json(e.member("value")))
      case "acquire":
        let result = try e.member("result").asString()
        try c.acquire({ _ in result == "release" ? .release : .complete })
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in try orderedCollectionState(c) })
  runtime.channel.addEvent = { [weak client] value, fresh in
    client?.events.append(.array([.string("add"), serializer.encode(value), .bool(fresh)]))
  }
  runtime.channel.acquireEvent = { [weak client] value, acquirer in
    client?.events.append(
      .array([.string("acquire"), serializer.encode(value), clientIdJSON(acquirer)]))
  }
  runtime.channel.completeEvent = { [weak client] value in
    client?.events.append(.array([.string("complete"), serializer.encode(value)]))
  }
  runtime.channel.localReleaseEvent = { [weak client] value, intentional in
    client?.events.append(
      .array([.string("localRelease"), serializer.encode(value), .bool(intentional)]))
  }
  return client
}
