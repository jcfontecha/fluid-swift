import FluidJS
import FluidPresence
import Testing

/// The upstream behaviors specs/presence.md says a faithful port must reproduce, each checked
/// against the 3.11.0 oracle by `npm run fuzz:presence` and pinned here by name.
@Suite("Presence upstream quirks")
struct UpstreamQuirkTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private func connected() throws -> PresenceManager {
    try prepareConnectedPresence(rig)
  }

  private func clientMapping(_ connection: String, attendee: String, timestamp: Int = 700) -> String {
    #""\#(connection)":{"rev":0,"timestamp":\#(timestamp),"value":"\#(attendee)"}"#
  }

  // MARK: Pres:Ack

  @Test("Ack: a local echo contaminates the average latency with NaN (serialized as null)")
  func localAckContaminatesLatency() throws {
    let presence = try connected()
    try rig.process(
      presence, #"{"type":"Pres:Ack","content":{"id":"ack-1"},"clientId":"localClient"}"#,
      local: true)
    let manager = try presence.notifications.getWorkspace(
      "name:testNotifications",
      WorkspaceSchema([("msgs", NotificationsFactory(initialSubscriptions: []))])
    ).notifications("msgs")
    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":1230,"avgLatency":null,"data":\
      {"system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}},\
      "n:name:testNotifications":{"msgs":{"localAttendeeId":{"rev":0,"timestamp":0,\
      "value":{"name":"ping","args":[]},"ignoreUnmonitored":true}}}}}}
      """)
    try manager.emit.broadcast("ping")
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("Ack: a remote Ack throws and changes nothing")
  func remoteAckThrows() throws {
    let presence = try connected()
    let attendeesBefore = presence.attendees.getAttendees().count
    #expect(throws: PresenceError.self) {
      try rig.process(presence, #"{"type":"Pres:Ack","content":{"id":"ack-1"},"clientId":"client4"}"#)
    }
    #expect(presence.attendees.getAttendees().count == attendeesBefore)
  }

  // MARK: Timestamps

  private func latestUpdate(_ presence: PresenceManager, timestamp: Int) throws {
    // timeModifier = received - (ownAverageLatency 10 + sender avgLatency 20 + sendTimestamp) = -20
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now - 10)),"avgLatency":20,\
      "data":{"system:presence":{"clientToSessionId":{\(clientMapping("client4", attendee: "attendeeId-4"))}},\
      "s:name:testWorkspace":{"cursor":{"attendeeId-4":{"rev":1,"timestamp":\(timestamp),"value":{"x":5}}}}}},\
      "clientId":"client4"}
      """)
  }

  private func cursor(_ presence: PresenceManager) throws -> LatestValueManagerImpl {
    try presence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([("cursor", LatestFactory(local: .object(JSObject()), clock: rig.clock))])
    ).latest("cursor")
  }

  @Test("timestamps: an unregistered workspace is shifted by the time modifier, a registered one keeps the sender's")
  func timestampsAreNormalizedDifferently() throws {
    let registeredPresence = try connected()
    rig.runtime.ignoresSignals = true
    let registered = try cursor(registeredPresence)
    try latestUpdate(registeredPresence, timestamp: 555)
    #expect(try registered.getRemotes().first?.metadata.timestamp == 555)

    let rig2 = try Rig()
    let unregisteredPresence = try prepareConnectedPresence(rig2)
    rig2.runtime.ignoresSignals = true
    try rig2.tick(0)
    try rig2.process(
      unregisteredPresence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig2.now - 10)),"avgLatency":20,\
      "data":{"system:presence":{"clientToSessionId":{\(clientMapping("client4", attendee: "attendeeId-4"))}},\
      "s:name:testWorkspace":{"cursor":{"attendeeId-4":{"rev":1,"timestamp":555,"value":{"x":5}}}}}},\
      "clientId":"client4"}
      """)
    // Registering later keeps the cached, shifted entry but does not replay events.
    let late = try unregisteredPresence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([("cursor", LatestFactory(local: .object(JSObject()), clock: rig2.clock))])
    ).latest("cursor")
    #expect(try late.getRemotes().first?.metadata.timestamp == 535)
  }

  // MARK: Validation cache

  @Test("a self value read through a validating getter caches validatedValue on the local state, which partial updates then send")
  func validatedValueLeaksIntoPartialUpdates() throws {
    let presence = try connected()
    let manager = try presence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([
        (
          "cursor",
          LatestFactory(local: try parse(#"{"x":1}"#), validator: { $0 }, clock: rig.clock)
        )
      ])
    ).latest("cursor")
    // Initial data is queued with the default 60ms latency. Reading self caches the validation.
    rig.runtime.signalsExpected = []
    rig.runtime.ignoresSignals = true
    _ = try manager.getRemote(presence.attendees.getMyself()).value.resolve()
    rig.runtime.ignoresSignals = false
    // The next local update queues a clone of the state, cache included (stale after the set).
    try manager.setLocal(try parse(#"{"x":3}"#))
    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":1290,"avgLatency":10,"data":\
      {"system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}},\
      "s:name:testWorkspace":{"cursor":{"localAttendeeId":{"rev":1,"timestamp":1230,"value":{"x":3},"validatedValue":{"x":1}}}}}}}
      """)
    try rig.tick(60)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("a received validatedValue is returned as is, without running the receiver's validator")
  func receivedValidatedValueSkipsValidator() throws {
    let presence = try connected()
    rig.runtime.ignoresSignals = true
    var calls = 0
    let manager = try presence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([
        (
          "cursor",
          LatestFactory(
            local: .object(JSObject()),
            validator: { raw in
              calls += 1
              return raw
            }, clock: rig.clock)
        )
      ])
    ).latest("cursor")
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now - 10)),"avgLatency":20,\
      "data":{"system:presence":{"clientToSessionId":{\(clientMapping("client4", attendee: "attendeeId-4"))}},\
      "s:name:testWorkspace":{"cursor":{"attendeeId-4":{"rev":1,"timestamp":555,"value":{"x":"raw"},\
      "validatedValue":{"x":"sender"}}}}}},"clientId":"client4"}
      """)
    let value = try #require(try manager.getRemotes().first?.value.resolve())
    #expect(value == (try parse(#"{"x":"sender"}"#)))
    #expect(calls == 0)
  }

  // MARK: Controls

  @Test("forced refresh interval of 10 or more is stored then throws; below 10 is stored as undefined")
  func forcedRefresh() throws {
    let presence = try connected()
    rig.runtime.ignoresSignals = true
    let manager = try cursor(presence)
    try manager.controls.setForcedRefreshIntervalMs(5)
    #expect(manager.controls.forcedRefreshIntervalMs == nil)
    #expect(throws: PresenceError.failed("Forced Refresh feature is not implemented")) {
      try manager.controls.setForcedRefreshIntervalMs(10)
    }
    #expect(manager.controls.forcedRefreshIntervalMs == 10)
    try manager.controls.setForcedRefreshIntervalMs(nil)
    #expect(manager.controls.forcedRefreshIntervalMs == nil)
  }

  @Test("workspace allowable latency falls back to the default when set to undefined")
  func workspaceLatencyDefault() throws {
    let presence = try connected()
    rig.runtime.ignoresSignals = true
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([]), settings: BroadcastControlSettings(allowableUpdateLatencyMs: 5))
    #expect(workspace.controls.allowableUpdateLatencyMs == 5)
    workspace.controls.setAllowableUpdateLatencyMs(nil)
    #expect(workspace.controls.allowableUpdateLatencyMs == 60)
  }

  // MARK: Registration

  @Test("registering the same key with a different factory kind throws a TypeError-style failure")
  func factoryMismatch() throws {
    let presence = try connected()
    rig.runtime.ignoresSignals = true
    _ = try cursor(presence)
    #expect(throws: PresenceError.failed("State \"cursor\" previously created by different State object.")) {
      _ = try presence.states.getWorkspace(
        "name:testWorkspace",
        WorkspaceSchema([("cursor", LatestMapFactory(clock: rig.clock))]))
    }
  }

  @Test("the same latest factory registered under two keys shares one captured initial state")
  func factoryStateShared() throws {
    let presence = try connected()
    rig.runtime.ignoresSignals = true
    let factory = LatestFactory(local: try parse(#"{"x":1}"#), clock: rig.clock)
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([("a", factory), ("b", factory)]))
    try workspace.latest("a").setLocal(try parse(#"{"x":2}"#))
    #expect(try workspace.latest("b").local == (try parse(#"{"x":2}"#)))
  }
}
