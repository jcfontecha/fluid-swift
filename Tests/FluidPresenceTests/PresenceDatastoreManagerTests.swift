import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/runtime/test/presenceDatastoreManager.spec.ts ("protocol handling").
@Suite("Presence/Runtime protocol handling")
struct PresenceDatastoreManagerTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private let attendee4Mapping = #""client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}"#
  private let attendee5Mapping = #""client5":{"rev":0,"timestamp":800,"value":"attendeeId-5"}"#
  private let attendee0Mapping = #""client0":{"rev":0,"timestamp":0,"value":"attendeeId-0"}"#
  private let localMapping = #""localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}"#

  @Test("does not signal when disconnected during initialization")
  func noSignalWhenDisconnected() throws {
    _ = try createPresenceManager(runtime: rig.runtime, attendeeId: "a")
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("sends join when connected during initialization")
  func sendsJoinWhenConnected() throws {
    _ = try prepareConnectedPresence(rig)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  private func joinClient(
    _ presence: PresenceManager, client: String, mapping: String, providers: [String]
  ) throws {
    let providerList = providers.map { "\"\($0)\"" }.joined(separator: ",")
    try rig.process(
      presence,
      """
      {"type":"Pres:ClientJoin","content":{"sendTimestamp":\(JSON.numberToString(rig.now - 50)),"avgLatency":50,\
      "data":{"system:presence":{"clientToSessionId":{\(mapping)}}},"updateProviders":[\(providerList)]},\
      "clientId":"\(client)"}
      """)
  }

  @Test("handles ClientJoin: when preferred responder, broadcasts after the named responder delay")
  func preferredResponder() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let updateTime = rig.now + BroadcastJoinResponseDelaysMs.namedResponder

    try joinClient(presence, client: "client4", mapping: attendee4Mapping, providers: ["localClient"])
    try rig.tick(BroadcastJoinResponseDelaysMs.namedResponder / 2)
    try joinClient(presence, client: "client5", mapping: attendee5Mapping, providers: ["localClient"])

    // One tick before the expected response time: nothing is sent.
    try rig.tick(updateTime - 1 - rig.now)

    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now + 1)),\
      "avgLatency":10,"isComplete":true,"data":{"system:presence":{"clientToSessionId":{\(localMapping),\
      \(attendee4Mapping),\(attendee5Mapping)}}},"joinResponseFor":["client4","client5"]}}
      """)
    try rig.tick(1)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("handles ClientJoin: when NOT preferred responder and no other responses, broadcasts after delay")
  func backupResponderBroadcasts() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    // 3 * named providers (client0 and client1) + quorum sequence order (third writer -> 2)
    let responderIndex = 3.0 * 2 + 2
    let updateTime =
      rig.now + BroadcastJoinResponseDelaysMs.namedResponder
      + BroadcastJoinResponseDelaysMs.backupResponderIncrement * responderIndex

    try joinClient(presence, client: "client4", mapping: attendee4Mapping, providers: ["client0", "client1"])
    try rig.tick(updateTime - rig.now - 1)

    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now + 1)),\
      "avgLatency":10,"isComplete":true,"data":{"system:presence":{"clientToSessionId":{\(localMapping),\
      \(attendee4Mapping)}}},"joinResponseFor":["client4"]}}
      """)
    try rig.tick(1)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  private func processClient0ResponseForClient4(_ presence: PresenceManager) throws {
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"avgLatency":10,"data":{"system:presence":\
      {"clientToSessionId":{\(attendee0Mapping),\(attendee4Mapping)}}},"isComplete":true,\
      "joinResponseFor":["client4"],"sendTimestamp":\(JSON.numberToString(rig.now - 10))},\
      "clientId":"client0"}
      """)
  }

  @Test("handles ClientJoin: when NOT preferred responder and other has fully responded, does not broadcast")
  func otherFullyResponded() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    try joinClient(presence, client: "client4", mapping: attendee4Mapping, providers: ["client0", "client1"])
    try rig.tick(BroadcastJoinResponseDelaysMs.namedResponder)
    try processClient0ResponseForClient4(presence)
    try rig.tick(100_000)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("handles ClientJoin: when NOT preferred responder and other has partially responded, broadcasts for the rest")
  func otherPartiallyResponded() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let responderIndex = 3.0 * 2 + 2
    let client4ResponseDelay =
      BroadcastJoinResponseDelaysMs.namedResponder
      + BroadcastJoinResponseDelaysMs.backupResponderIncrement * responderIndex
    let client4UpdateTime = rig.now + client4ResponseDelay
    let delayToJoinClient5 = client4ResponseDelay / 2
    let client5UpdateTime = client4UpdateTime + delayToJoinClient5

    try joinClient(presence, client: "client4", mapping: attendee4Mapping, providers: ["client0", "client1"])
    try rig.tick(delayToJoinClient5)
    try joinClient(presence, client: "client5", mapping: attendee5Mapping, providers: ["client0", "client1"])

    try rig.tick(client4UpdateTime - rig.now - 1)
    try processClient0ResponseForClient4(presence)
    try rig.tick(client5UpdateTime - rig.now - 1)

    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now + 1)),\
      "avgLatency":10,"isComplete":true,"data":{"system:presence":{"clientToSessionId":{\(localMapping),\
      \(attendee4Mapping),\(attendee5Mapping),\(attendee0Mapping)}}},"joinResponseFor":["client5"]}}
      """)
    try rig.tick(1)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  // MARK: Receiving DatastoreUpdate

  private let systemUpdate =
    #""system:presence":{"clientToSessionId":{"client1":{"rev":0,"timestamp":0,"value":"attendeeId-1"}}}"#
  private let statesUpdate = #"{"latest":{"attendeeId-1":{"rev":1,"timestamp":0,"value":{}}}}"#
  private let notificationsUpdate =
    #"{"testEvents":{"attendeeId-1":{"rev":0,"timestamp":0,"value":{},"ignoreUnmonitored":true}}}"#

  private func datastoreUpdate(
    _ presence: PresenceManager, workspaces: String, extra: String = "", client: String = "client1"
  ) throws {
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now - 10)),\
      "avgLatency":20,"data":{\(systemUpdate),\(workspaces)}\(extra)},"clientId":"\(client)"}
      """)
  }

  private func activations(_ presence: PresenceManager) -> Recorder<String> {
    let recorder = Recorder<String>()
    presence.events.on { event in
      if case .workspaceActivated(let address, let type) = event {
        recorder.record("\(address):\(type.rawValue)")
      }
    }
    return recorder
  }

  @Test("receiving DatastoreUpdate with unregistered States workspace emits 'workspaceActivated'")
  func activatesStates() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""s:name:testStateWorkspace":\#(statesUpdate)"#)
    #expect(recorder.values == ["name:testStateWorkspace:States"])
  }

  @Test("receiving DatastoreUpdate with unregistered Notifications workspace emits 'workspaceActivated'")
  func activatesNotifications() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""n:name:testNotificationWorkspace":\#(notificationsUpdate)"#)
    #expect(recorder.values == ["name:testNotificationWorkspace:Notifications"])
  }

  @Test("receiving DatastoreUpdate with unregistered workspace of unknown type emits 'workspaceActivated'")
  func activatesUnknown() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""u:name:testUnknownWorkspace":\#(statesUpdate)"#)
    #expect(recorder.values == ["name:testUnknownWorkspace:Unknown"])
  }

  @Test("receiving DatastoreUpdate with registered workspace does NOT emit 'workspaceActivated'")
  func registeredDoesNotActivate() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    _ = try presence.states.getWorkspace(
      "name:testStateWorkspace",
      WorkspaceSchema([("latest", LatestFactory(local: .object(JSObject()), clock: rig.clock))]))
    // Registering sent the initial value; the connected signals queue is not under test here.
    rig.runtime.ignoresSignals = true
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""s:name:testStateWorkspace":\#(statesUpdate)"#)
    #expect(recorder.values.isEmpty)
  }

  @Test("receiving DatastoreUpdate with an unrecognized internal address or an invalid public address does NOT emit 'workspaceActivated'")
  func malformedAddressesDoNotActivate() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""sn:name:testStateWorkspace":\#(statesUpdate)"#)
    try datastoreUpdate(presence, workspaces: #""s:testStateWorkspace":\#(statesUpdate)"#)
    #expect(recorder.values.isEmpty)
  }

  @Test("receiving DatastoreUpdate with a workspace that has already been seen does NOT emit 'workspaceActivated'")
  func seenDoesNotActivate() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    let recorder = activations(presence)
    try datastoreUpdate(presence, workspaces: #""s:name:testStateWorkspace":\#(statesUpdate)"#)
    try datastoreUpdate(presence, workspaces: #""s:name:testStateWorkspace":\#(statesUpdate)"#)
    #expect(recorder.values.count == 1)
  }

  @Test("receiving DatastoreUpdate with acknowledgementId sends targeted acknowledgment message back to requestor")
  func sendsAcknowledgement() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.tick(10)
    try rig.expect(#"{"type":"Pres:Ack","content":{"id":"ackID"},"targetClientId":"client4"}"#)
    try datastoreUpdate(
      presence, workspaces: #""s:name:testStateWorkspace":\#(statesUpdate)"#,
      extra: #","acknowledgementId":"ackID""#, client: "client4")
    try rig.runtime.assertAllSignalsSubmitted()
  }

  // MARK: Unrecognized messages

  @Test("receiving an unrecognized message that is NOT optional, throws")
  func unrecognizedThrows() throws {
    let presence = try prepareConnectedPresence(rig)
    #expect(throws: PresenceError.assertionFailed("0xcbc")) {
      try rig.process(presence, #"{"type":"Pres:Future","content":{},"clientId":"client1"}"#)
    }
  }

  @Test("receiving an unrecognized message that is optional, ignores it and does NOT throw")
  func unrecognizedOptionalIgnored() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.process(
      presence, #"{"type":"Pres:Future","content":{},"clientId":"client1"}"#, addressChain: ["?"])
  }
}
