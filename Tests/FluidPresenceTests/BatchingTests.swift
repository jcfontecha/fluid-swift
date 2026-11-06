import FluidJS
import FluidPresence
import Testing

/// Ports the scheduling rules of presence-runtime/src/states/test/batching.spec.ts and
/// specs/presence.md "Workspace, batching and timers".
@Suite("Presence/States batching")
struct BatchingTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private let system =
    #""system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}}"#

  private func cursorFactory(latency: Double? = nil) throws -> LatestFactory {
    LatestFactory(
      local: try parse(#"{"x":1}"#),
      settings: latency.map { BroadcastControlSettings(allowableUpdateLatencyMs: $0) }, clock: rig.clock)
  }

  private func update(sendTimestamp: Int, rev: Int, timestamp: Int, x: Int) -> String {
    """
    {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(sendTimestamp),"avgLatency":10,"data":\
    {\(system),"s:name:testWorkspace":{"cursor":{"localAttendeeId":{"rev":\(rev),"timestamp":\(timestamp),"value":{"x":\(x)}}}}}}}
    """
  }

  @Test("updates within the allowable latency are merged into one signal at the first deadline")
  func mergedAtDeadline() throws {
    let presence = try prepareConnectedPresence(rig)
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([("cursor", try cursorFactory())]))
    // Registered at 1230 with the default 60ms latency: due at 1290.
    try rig.tick(10)
    try workspace.latest("cursor").setLocal(try parse(#"{"x":2}"#))
    try rig.expect(update(sendTimestamp: 1290, rev: 1, timestamp: 1240, x: 2))
    try rig.tick(49)
    #expect(rig.runtime.signalsExpected.count == 1)
    try rig.tick(1)
    try rig.runtime.assertAllSignalsSubmitted()
    // Nothing further is queued.
    try rig.tick(1000)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("a manager latency of 0 sends immediately")
  func immediate() throws {
    let presence = try prepareConnectedPresence(rig)
    try rig.expect(update(sendTimestamp: 1230, rev: 0, timestamp: 1230, x: 1))
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([("cursor", try cursorFactory(latency: 0))]))
    try rig.runtime.assertAllSignalsSubmitted()

    try rig.expect(update(sendTimestamp: 1230, rev: 1, timestamp: 1230, x: 2))
    try workspace.latest("cursor").setLocal(try parse(#"{"x":2}"#))
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("an update with an earlier deadline than the pending timer replaces the timer")
  func earlierDeadlineReplacesTimer() throws {
    let presence = try prepareConnectedPresence(rig)
    // Registered at 1230 with the default 60ms latency: the timer is due at 1290.
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([("cursor", try cursorFactory())]))
    let cursor = try workspace.latest("cursor")
    cursor.controls.allowableUpdateLatencyMs = 10
    try cursor.setLocal(try parse(#"{"x":2}"#))
    try rig.expect(update(sendTimestamp: 1240, rev: 1, timestamp: 1230, x: 2))
    try rig.tick(10)
    try rig.runtime.assertAllSignalsSubmitted()
    try rig.tick(1000)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("a local update while disconnected is not queued; the join carries the current state")
  func disconnectedUpdateNotQueued() throws {
    rig.runtime.clientId = nil
    rig.runtime.joined = false
    try rig.runtime.removeMember(localConnection)
    let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: localAttendeeId)
    let workspace = try presence.states.getWorkspace(
      "name:testWorkspace", WorkspaceSchema([("cursor", try cursorFactory())]))
    try workspace.latest("cursor").setLocal(try parse(#"{"x":2}"#))

    try rig.expect(
      """
      {"type":"Pres:ClientJoin","content":{"sendTimestamp":1000,"avgLatency":0,"data":\
      {\(system),"s:name:testWorkspace":{"cursor":{"localAttendeeId":{"rev":1,"timestamp":1000,"value":{"x":2}}}}},\
      "updateProviders":["client0","client1","client3"]}}
      """)
    try rig.runtime.connect(localConnection, oldClientId: nil)
    try rig.runtime.assertAllSignalsSubmitted()
    // No queued update follows the join.
    try rig.tick(1000)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("joining alone still sends ClientJoin with the full datastore and no providers")
  func joinAlone() throws {
    let lone = try Rig()
    for id in ["client0", "client1", "client3", "client4", "client5", "client6", "client7"] {
      try lone.runtime.removeMember(JSString(id))
    }
    lone.runtime.clientId = localConnection
    lone.runtime.joined = true
    try lone.expect(try outbound(basicClientJoin(time: 1000, updateProviders: [])))
    _ = try createPresenceManager(runtime: lone.runtime, attendeeId: localAttendeeId)
    try lone.runtime.assertAllSignalsSubmitted()
  }
}
