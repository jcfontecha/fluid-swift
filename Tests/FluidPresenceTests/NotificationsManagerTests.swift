import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/states/test/notificationsManager.spec.ts.
@Suite("Presence/States NotificationsManager")
struct NotificationsManagerTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private func notifications(
    _ presence: PresenceManager, subscriptions: [(name: JSString, listener: NotificationListener)] = []
  ) throws -> NotificationsManagerImpl {
    try presence.notifications.getWorkspace(
      "name:testNotifications",
      WorkspaceSchema([("msgs", NotificationsFactory(initialSubscriptions: subscriptions))])
    ).notifications("msgs")
  }

  private func receive(_ presence: PresenceManager, name: String, args: String = "[]") throws {
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now)),"avgLatency":0,\
      "data":{"system:presence":{"clientToSessionId":{"client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}}},\
      "n:name:testNotifications":{"msgs":{"attendeeId-4":{"rev":0,"timestamp":0,\
      "value":{"name":"\(name)","args":\(args)},"ignoreUnmonitored":true}}}}},"clientId":"client4"}
      """)
  }

  @Test("emit.broadcast sends a broadcast signal immediately")
  func broadcastSignal() throws {
    let presence = try prepareConnectedPresence(rig)
    let manager = try notifications(presence)
    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":1230,"avgLatency":10,"data":\
      {"system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}},\
      "n:name:testNotifications":{"msgs":{"localAttendeeId":{"rev":0,"timestamp":0,\
      "value":{"name":"ping","args":["hello",3]},"ignoreUnmonitored":true}}}}}}
      """)
    try manager.emit.broadcast("ping", [.string("hello"), .number(3)])
    try rig.runtime.assertAllSignalsSubmitted()
  }

  /// specs/presence.md: `unicast` passes the target as an option the queue layer drops, so the
  /// signal is the same broadcast and carries no target.
  @Test("emit.unicast is sent as a broadcast with no target")
  func unicastIsBroadcast() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try notifications(presence)
    try rig.process(
      presence,
      basicClientJoin(
        time: rig.now - 50, attendeeId: "attendeeId-4", connection: "client4",
        updateProviders: ["client0"], averageLatency: 50))
    let target = try presence.attendees.getAttendee("attendeeId-4")
    rig.runtime.ignoresSignals = false
    try rig.expect(
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":1230,"avgLatency":10,"data":\
      {"system:presence":{"clientToSessionId":{"localClient":{"rev":0,"timestamp":1000,"value":"localAttendeeId"}}},\
      "n:name:testNotifications":{"msgs":{"localAttendeeId":{"rev":0,"timestamp":0,\
      "value":{"name":"ping","args":[]},"ignoreUnmonitored":true}}}}}}
      """)
    try manager.emit.unicast("ping", target)
    try rig.runtime.assertAllSignalsSubmitted()
  }

  @Test("unicast to an attendee that was never connected throws before sending")
  func unicastNeverConnected() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try notifications(presence)
    // A collateral attendee (known only through a mapping from someone else) has a connection ID;
    // the local attendee before connecting is the never-connected case.
    let idle = try createPresenceManager(runtime: try Rig().runtime, attendeeId: "idle")
    #expect(throws: PresenceError.failed("Client has never been connected")) {
      try manager.emit.unicast("ping", idle.attendees.getMyself())
    }
  }

  @Test("raises named event when notification is received")
  func namedEvent() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let recorder = Recorder<String>()
    let manager = try notifications(
      presence,
      subscriptions: [
        (
          "ping",
          { sender, args in recorder.record("\(sender.attendeeId) \(JSON.stringify(.array(args)))") }
        )
      ])
    let unattended = Recorder<String>()
    manager.events.on { event in
      if case .unattendedNotification(let name, _, _) = event {
        unattended.record(name.description)
      }
    }
    try receive(presence, name: "ping", args: #"["x",1]"#)
    try receive(presence, name: "ping", args: #"["x",1]"#)
    #expect(recorder.values == [#"attendeeId-4 ["x",1]"#, #"attendeeId-4 ["x",1]"#])
    #expect(unattended.values.isEmpty)
  }

  @Test("raises `unattendedNotification` when an unrecognized notification is received")
  func unattended() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try notifications(presence, subscriptions: [("ping", { _, _ in })])
    let recorder = Recorder<String>()
    manager.events.on { event in
      if case .unattendedNotification(let name, let sender, let content) = event {
        recorder.record("\(name) \(sender.attendeeId) \(JSON.stringify(.array(content)))")
      }
    }
    try receive(presence, name: "other", args: "[1]")
    #expect(recorder.values == ["other attendeeId-4 [1]"])
  }

  @Test("removed listeners are not called when a notification is received")
  func removedListeners() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    let manager = try notifications(presence)
    var calls = 0
    let off = manager.notifications.on("ping") { _, _ in calls += 1 }
    try receive(presence, name: "ping")
    off()
    try receive(presence, name: "ping")
    #expect(calls == 1)
  }

  @Test("a notification for an unregistered manager is discarded, not kept for later registration")
  func unregisteredNotificationDiscarded() throws {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    try receive(presence, name: "ping")
    let recorder = Recorder<String>()
    let manager = try notifications(presence)
    manager.events.on { event in
      if case .unattendedNotification(let name, _, _) = event {
        recorder.record(name.description)
      }
    }
    #expect(recorder.values.isEmpty)
  }
}
