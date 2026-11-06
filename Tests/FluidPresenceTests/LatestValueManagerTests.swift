import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/states/test/latestValueManager.spec.ts and the validator caching
/// of schemaValidation/valueManagers.spec.ts.
@Suite("Presence/States Latest")
struct LatestValueManagerTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private func workspace(
    _ presence: PresenceManager, local: JSONValue? = nil, validator: StateSchemaValidator? = nil
  ) throws -> LatestValueManagerImpl {
    let initial = try local ?? parse(#"{"x":1}"#)
    return try presence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([("cursor", LatestFactory(local: initial, validator: validator, clock: rig.clock))])
    ).latest("cursor")
  }

  @Test("can set and get object, empty object, null and array as initial value")
  func initialValues() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    for (index, text) in ["{}", #"{"x":1,"y":"a"}"#, "null", "[]", "[1,2]"].enumerated() {
      let value = try parse(text)
      let manager = try presence.states.getWorkspace(
        JSString("name:w\(index)"),
        WorkspaceSchema([("v", LatestFactory(local: value, clock: rig.clock))])
      ).latest("v")
      #expect(manager.local == value)
    }
  }

  @Test("localUpdated event is fired with new value when local value is updated")
  func localUpdatedEvent() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try workspace(presence)
    let recorder = Recorder<JSONValue>()
    manager.events.on { event in
      if case .localUpdated(let value) = event {
        recorder.record(value)
      }
    }
    try manager.setLocal(try parse(#"{"x":2}"#))
    try manager.setLocal(.null)
    #expect(recorder.values == [try parse(#"{"x":2}"#), .null])
    #expect(manager.local == .null)
  }

  @Test("`presence` provides the Presence it was created under")
  func presenceIdentity() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try workspace(presence)
    #expect(manager.presence === presence)
  }

  @Test("local update sends a batched partial update with the current connection mapping first")
  func localUpdateSignal() throws {
    let presence = try prepareConnectedPresence(rig)
    // Registered at 1230. The workspace default allowable latency is 60ms, so the send is due at 1290.
    _ = try workspace(presence)
    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":1290,"avgLatency":10,"data":\
      {"system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}},\
      "s:name:testWorkspace":{"cursor":{"localAttendeeId":{"rev":0,"timestamp":1230,"value":{"x":1}}}}}}}
      """)
    try rig.tick(59)
    #expect(rig.runtime.signalsExpected.count == 1)
    try rig.tick(1)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("remote update stores the value, emits remoteUpdated with the wire timestamp and ignores older revisions")
  func remoteUpdate() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try workspace(presence)
    let recorder = Recorder<String>()
    manager.events.on { event in
      if case .remoteUpdated(let data) = event {
        recorder.record(
          "\(data.attendee.attendeeId) \(JSON.stringify(data.value.resolve() ?? .null)) \(JSON.numberToString(data.metadata.revision)) \(JSON.numberToString(data.metadata.timestamp ?? -1))"
        )
      }
    }
    func update(rev: Int, x: Int) throws {
      try rig.process(
        presence,
        """
        {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now)),"avgLatency":0,\
        "data":{"system:presence":{"clientToSessionId":{"client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}}},\
        "s:name:testWorkspace":{"cursor":{"attendeeId-4":{"rev":\(rev),"timestamp":555,"value":{"x":\(x)}}}}}},\
        "clientId":"client4"}
        """)
    }
    try update(rev: 1, x: 5)
    try update(rev: 1, x: 6)
    try update(rev: 0, x: 7)
    #expect(recorder.values == [#"attendeeId-4 {"x":5} 1 555"#])
    #expect(try manager.getRemotes().count == 1)
    #expect(try manager.getStateAttendees().map(\.attendeeId) == ["attendeeId-4"])
  }

  @Test("`getRemote` throws for an attendee without an entry")
  func getRemoteUnknown() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try workspace(presence)
    rig.runtime.ignoresSignals = true
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now)),"avgLatency":0,\
      "data":{"system:presence":{"clientToSessionId":{"client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}}}}},\
      "clientId":"client4"}
      """)
    let attendee = try presence.attendees.getAttendee("attendeeId-4")
    #expect(throws: PresenceError.failed("No entry for attendee")) {
      _ = try manager.getRemote(attendee)
    }
  }

  // MARK: Validators

  @Test("validator runs once per value on first access and its result, even undefined, is cached")
  func validatorCaches() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    var calls = 0
    let manager = try workspace(
      presence,
      validator: { raw in
        calls += 1
        return nil
      })
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now)),"avgLatency":0,\
      "data":{"system:presence":{"clientToSessionId":{"client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}}},\
      "s:name:testWorkspace":{"cursor":{"attendeeId-4":{"rev":1,"timestamp":555,"value":{"x":"bad"}}}}}},\
      "clientId":"client4"}
      """)
    let remote = try #require(try manager.getRemotes().first)
    #expect(calls == 0)
    #expect(remote.value.resolve() == nil)
    #expect(remote.value.resolve() == nil)
    #expect(calls == 1)
    // Raw state is retained and a new getter over the same state reuses the cache.
    #expect(try manager.getRemotes().first?.value.resolve() == nil)
    #expect(calls == 1)
  }
}
