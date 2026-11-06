import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/test/testUtils.ts (the parts these tests use). Expected signals are
/// written as JSON text in the producers' key order, which the wire format pins.

func parse(_ text: String) throws -> JSONValue {
  try JSON.parse(text)
}

/// A runtime on a manual clock starting at 1000, as the TS specs' `initialTime`.
final class Rig {
  let clock = ManualPresenceClock(start: 1000)
  let runtime: MockEphemeralRuntime

  /// Errors thrown by timer callbacks. TS fake timers propagate them out of `tick`.
  var timerErrors: [any Error] = []

  init() throws {
    runtime = try MockEphemeralRuntime(clock: clock)
    clock.onError = { [unowned self] error in
      timerErrors.append(error)
    }
  }

  func expect(_ signal: String) throws {
    runtime.signalsExpected.append(try parse(signal))
  }

  func tick(_ ms: Double) throws {
    clock.advance(by: ms)
    if let error = timerErrors.first {
      timerErrors.removeAll()
      throw error
    }
  }

  var now: Double { clock.now() }

  /// `createProcessSignal`: the message goes through JSON text so only JSON data reaches presence.
  func process(
    _ presence: PresenceManager, _ message: String, local: Bool = false,
    addressChain: [JSString] = []
  ) throws {
    let inbound = try InboundExtensionMessage(json: JSON.parse(message))
    try presence.processSignal(addressChain: addressChain, message: inbound, local: local)
  }
}

let localAttendeeId: JSString = "localAttendeeId"
let localConnection: JSString = "localClient"

/// `generateBasicClientJoin`: the join signal of a client initialized while connected, as JSON.
func basicClientJoin(
  time: Double, attendeeId: String = "localAttendeeId", connection: String = "localClient",
  updateProviders: [String] = ["client0", "client1", "client3"], connectionOrder: Int = 0,
  averageLatency: Double = 0, priorMappings: String = ""
) -> String {
  let providers = updateProviders.map { "\"\($0)\"" }.joined(separator: ",")
  let time = JSON.numberToString(time)
  return """
    {"type":"Pres:ClientJoin","content":{"sendTimestamp":\(time),"avgLatency":\(JSON.numberToString(averageLatency)),\
    "data":{"system:presence":{"clientToSessionId":{\(priorMappings)"\(connection)":{"rev":\(connectionOrder),\
    "timestamp":\(time),"value":"\(attendeeId)"}}}},"updateProviders":[\(providers)]},"clientId":"\(connection)"}
    """
}

/// Strips the `clientId` that only inbound messages carry, giving the outbound form.
func outbound(_ inbound: String) throws -> String {
  var object = try parse(inbound).asObject()
  object["clientId"] = nil
  return JSON.stringify(.object(object))
}

/// `prepareConnectedPresence`: presence created while connected and already in the audience, the
/// local join echoed back and a fake complete join response processed.
func prepareConnectedPresence(_ rig: Rig, attendeeId: JSString = localAttendeeId) throws
  -> PresenceManager
{
  rig.runtime.clientId = localConnection
  rig.runtime.joined = true

  let join = basicClientJoin(time: rig.now, attendeeId: attendeeId.description)
  try rig.expect(try outbound(join))
  let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: attendeeId)
  try rig.runtime.assertAllSignalsSubmitted()

  // Pass a little time (to mimic reality), then return the [local] join signal.
  try rig.tick(10)
  try rig.process(presence, join, local: true)

  // Pass time (to mimic the likely response), then send a fake join response. It convinces
  // the presence manager that it has full knowledge, which lets it respond to others' joins.
  try rig.tick(BroadcastJoinResponseDelaysMs.namedResponder + 20)
  var response = try parse(join).asObject()
  guard var content = try response["content"]?.asObject() else {
    throw UnexpectedSignal(description: "join without content")
  }
  content["isComplete"] = .bool(true)
  content["joinResponseFor"] = .array([.string(localConnection)])
  response["content"] = .object(content)
  response["type"] = .string("Pres:DatastoreUpdate")
  response["clientId"] = .string("client0")
  try rig.process(presence, JSON.stringify(.object(response)))
  return presence
}

/// Collects values an event handler is called with.
final class Recorder<Value> {
  var values: [Value] = []

  func record(_ value: Value) {
    values.append(value)
  }
}
