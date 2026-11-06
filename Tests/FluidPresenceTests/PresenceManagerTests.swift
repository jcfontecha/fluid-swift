import FluidDriverDefinitions
import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/runtime/test/presenceManager.spec.ts (session lifecycle).
@Suite("Presence/Runtime PresenceManager")
struct PresenceManagerTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  @Test("throws when unknown attendee is requested via `getAttendee`")
  func unknownAttendee() throws {
    let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: "a")
    #expect(throws: PresenceError.failed("Attendee not found")) {
      _ = try presence.attendees.getAttendee("unknown")
    }
  }

  private func events(_ presence: PresenceManager) -> Recorder<String> {
    let recorder = Recorder<String>()
    presence.attendees.events.on { event in
      switch event {
      case .attendeeConnected(let attendee): recorder.record("connected:\(attendee.attendeeId)")
      case .attendeeDisconnected(let attendee): recorder.record("disconnected:\(attendee.attendeeId)")
      }
    }
    return recorder
  }

  @Test("self attendee is announced via `attendeeConnected` upon connect while self is in audience")
  func selfAnnouncedOnConnect() throws {
    rig.runtime.clientId = nil
    rig.runtime.joined = false
    try rig.runtime.removeMember(localConnection)
    let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: localAttendeeId)
    let recorder = events(presence)

    try rig.expect(try outbound(basicClientJoin(time: rig.now)))
    try rig.runtime.connect(localConnection, oldClientId: nil)

    #expect(recorder.values == ["connected:localAttendeeId"])
    #expect(presence.attendees.getMyself().getConnectionStatus() == .connected)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("self attendee has status Disconnected when presence initializes while container is disconnected")
  func selfDisconnectedWhenInitializedDisconnected() throws {
    let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: localAttendeeId)
    let myself = presence.attendees.getMyself()
    #expect(myself.getConnectionStatus() == .disconnected)
    #expect(throws: PresenceError.failed("Client has never been connected")) {
      _ = try myself.getConnectionId()
    }
  }

  @Test("self attendee has status Disconnected when runtime is connected but self is not yet in Audience")
  func selfDisconnectedWhenNotInAudience() throws {
    try rig.runtime.removeMember(localConnection)
    rig.runtime.clientId = localConnection
    rig.runtime.joined = true
    let presence = try createPresenceManager(runtime: rig.runtime, attendeeId: localAttendeeId)
    #expect(presence.attendees.getMyself().getConnectionStatus() == .disconnected)
  }

  @Test("self attendee is announced via `attendeeDisconnected` when local client disconnects")
  func selfAnnouncedOnDisconnect() throws {
    let presence = try prepareConnectedPresence(rig)
    let recorder = events(presence)
    try rig.runtime.disconnect()
    #expect(recorder.values == ["disconnected:localAttendeeId"])
    #expect(presence.attendees.getMyself().getConnectionStatus() == .disconnected)
  }

  // MARK: Remote attendees

  /// Join signal of a remote attendee, with an audience-agnostic sender (client4 is in the audience).
  private func join(
    _ presence: PresenceManager, attendee: String, connection: String, order: Int = 0,
    prior: String = ""
  ) throws {
    try rig.process(
      presence,
      basicClientJoin(
        time: rig.now - 50, attendeeId: attendee, connection: connection,
        updateProviders: ["localClient"], connectionOrder: order, averageLatency: 50,
        priorMappings: prior))
  }

  @Test("attendee that is joining first time is announced via `attendeeConnected` with status Connected")
  func remoteJoinAnnounced() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let recorder = events(presence)
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    #expect(recorder.values == ["connected:attendeeId-4"])
    let attendee = try presence.attendees.getAttendee("attendeeId-4")
    #expect(try attendee.getConnectionId() == "client4")
    #expect(attendee.getConnectionStatus() == .connected)
    #expect(try presence.attendees.getAttendee("client4") === attendee)
  }

  @Test("attendee that is joining even if unknown to the audience is announced")
  func remoteJoinAnnouncedWhenUnknownToAudience() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let recorder = events(presence)
    try join(presence, attendee: "attendeeId-9", connection: "client9")
    #expect(recorder.values == ["connected:attendeeId-9"])
  }

  @Test("attendee that is already known and rejoins with the same connection (duplicate signal) is NOT announced")
  func duplicateJoinNotAnnounced() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    let recorder = events(presence)
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    #expect(recorder.values.isEmpty)
  }

  @Test("attendee that is rejoining with a different connection is NOT announced again while connected, and updates its connection")
  func rejoinUpdatesConnection() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    let recorder = events(presence)
    try join(
      presence, attendee: "attendeeId-4", connection: "client7", order: 1,
      prior: #""client4":{"rev":0,"timestamp":950,"value":"attendeeId-4"},"#)
    #expect(recorder.values.isEmpty)
    let attendee = try presence.attendees.getAttendee("attendeeId-4")
    #expect(try attendee.getConnectionId() == "client7")
    #expect(try presence.attendees.getAttendee("client4") === attendee)
  }

  @Test("attendee whose connection is removed is announced via `attendeeDisconnected`, once")
  func removedConnectionAnnounced() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    let recorder = events(presence)
    try rig.runtime.removeMember("client4")
    #expect(recorder.values == ["disconnected:attendeeId-4"])
    try rig.runtime.audience.removeMember("client4")
    #expect(recorder.values == ["disconnected:attendeeId-4"])
  }

  @Test("an unknown connection that is removed is not announced via `attendeeDisconnected`")
  func unknownRemovalIgnored() throws {
    let presence = try prepareConnectedPresence(rig)
    let recorder = events(presence)
    try rig.runtime.removeMember("client5")
    #expect(recorder.values.isEmpty)
  }

  @Test("`getAttendees` returns each attendee once, though it is mapped by attendee and connection ID")
  func attendeesDeduplicated() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    let ids = presence.attendees.getAttendees().map(\.attendeeId)
    #expect(ids == ["localAttendeeId", "attendeeId-4"])
  }

  // MARK: Stale connections after local reconnect

  @Test("updates status of attendee with stale connection after 30s delay upon local reconnection")
  func staleConnectionResolved() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")
    let recorder = events(presence)

    try rig.runtime.disconnect()
    // While disconnected the audience loses client4; the local client reconnects.
    try rig.runtime.audience.removeMember("client4")
    try rig.runtime.connect("localClient2", oldClientId: "localClient")
    #expect(recorder.values.contains("connected:localAttendeeId"))

    try rig.tick(29_999)
    #expect(try presence.attendees.getAttendee("attendeeId-4").getConnectionStatus() == .connected)
    try rig.tick(1)
    #expect(try presence.attendees.getAttendee("attendeeId-4").getConnectionStatus() == .disconnected)
    #expect(recorder.values.filter { $0 == "disconnected:attendeeId-4" }.count == 1)
  }

  @Test("does not update status of attendee with stale connection if attendee rejoins")
  func staleConnectionNotResolvedWhenRejoined() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try join(presence, attendee: "attendeeId-4", connection: "client4")

    try rig.runtime.disconnect()
    try rig.runtime.connect("localClient2", oldClientId: "localClient")
    // The attendee shows up again in the audience and sends a newer join.
    try rig.tick(1000)
    try join(
      presence, attendee: "attendeeId-4", connection: "client7", order: 1,
      prior: #""client4":{"rev":0,"timestamp":950,"value":"attendeeId-4"},"#)
    try rig.tick(30_000)
    #expect(try presence.attendees.getAttendee("attendeeId-4").getConnectionStatus() == .connected)
  }
}
