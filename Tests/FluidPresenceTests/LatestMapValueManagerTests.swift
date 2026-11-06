import FluidJS
import FluidPresence
import Testing

/// Ports presence-runtime/src/states/test/latestMapValueManager.spec.ts and the map rules of
/// specs/presence.md "Latest map manager".
@Suite("Presence/States LatestMap")
struct LatestMapValueManagerTests {
  let rig: Rig

  init() throws {
    rig = try Rig()
  }

  private func manager(
    _ presence: PresenceManager, local: String = "{}", keyValidator: KeySchemaValidator? = nil
  ) throws -> LatestMapValueManagerImpl {
    guard case .object(let items) = try parse(local) else {
      throw UnexpectedSignal(description: "local must be an object")
    }
    return try presence.states.getWorkspace(
      "name:testWorkspace",
      WorkspaceSchema([
        ("cells", LatestMapFactory(local: items, keyValidator: keyValidator, clock: rig.clock))
      ])
    ).latestMap("cells")
  }

  private func connected() throws -> PresenceManager {
    let presence = try prepareConnectedPresence(rig)
    rig.runtime.ignoresSignals = true
    return presence
  }

  @Test("localItemUpdated event is fired with new value when local value is updated")
  func localItemUpdated() throws {
    let presence = try connected()
    let map = try manager(presence)
    let recorder = Recorder<String>()
    map.events.on { event in
      if case .localItemUpdated(let key, let value) = event {
        recorder.record("\(key)=\(JSON.stringify(value))")
      }
    }
    try map.local.set("a", .number(1))
    try map.local.set("a", .number(2))
    #expect(recorder.values == ["a=1", "a=2"])
    #expect(map.local.get("a") == .number(2))
    #expect(map.local.keys() == ["a"])
  }

  @Test("localItemRemoved event is fired when a defined local value is deleted, and delete reports whether it did")
  func localItemRemoved() throws {
    let presence = try connected()
    let map = try manager(presence, local: #"{"a":1}"#)
    let recorder = Recorder<JSString>()
    map.events.on { event in
      if case .localItemRemoved(let key) = event {
        recorder.record(key)
      }
    }
    #expect(try map.local.delete("a"))
    #expect(try !map.local.delete("a"))
    #expect(try !map.local.delete("missing"))
    #expect(recorder.values == ["a"])
    #expect(!map.local.has("a"))
  }

  @Test("`clear` is not implemented")
  func clearNotImplemented() throws {
    let presence = try connected()
    let map = try manager(presence)
    #expect(throws: PresenceError.failed("Method not implemented.")) {
      try map.local.clear()
    }
  }

  /// specs/presence.md: tombstones stay in items, so setting a key again after deleting it does not
  /// increment the defined count and `size` undercounts while keys/has/get show the value.
  @Test("size undercounts after a key is set again following a delete")
  func sizeAfterTombstoneResurrection() throws {
    let presence = try connected()
    let map = try manager(presence, local: #"{"a":1}"#)
    #expect(map.local.size == 1)
    try map.local.delete("a")
    #expect(map.local.size == 0)
    try map.local.set("a", .number(2))
    #expect(map.local.size == 0)
    #expect(map.local.has("a"))
    #expect(map.local.keys() == ["a"])
  }

  private func remoteUpdate(_ presence: PresenceManager, rev: Int, items: String) throws {
    try rig.process(
      presence,
      """
      {"type":"Pres:DatastoreUpdate","content":{"sendTimestamp":\(JSON.numberToString(rig.now)),"avgLatency":0,\
      "data":{"system:presence":{"clientToSessionId":{"client4":{"rev":0,"timestamp":700,"value":"attendeeId-4"}}},\
      "s:name:testWorkspace":{"cells":{"attendeeId-4":{"rev":\(rev),"items":{\(items)}}}}}},"clientId":"client4"}
      """)
  }

  @Test("remote items update, remove and late partial updates keep newer unrelated keys")
  func remoteItems() throws {
    let presence = try connected()
    let map = try manager(presence)
    let recorder = Recorder<String>()
    map.events.on { event in
      switch event {
      case .remoteItemUpdated(let data):
        recorder.record("updated \(data.key) \(JSON.stringify(data.value.resolve() ?? .null))")
      case .remoteItemRemoved(let data):
        recorder.record("removed \(data.key)")
      case .remoteUpdated(let data):
        recorder.record("remoteUpdated \(data.items.keys.map(\.description))")
      default: break
      }
    }
    try remoteUpdate(presence, rev: 2, items: #""a":{"rev":2,"timestamp":10,"value":1},"b":{"rev":1,"timestamp":10,"value":5}"#)
    // A late partial update with an older directory revision still applies its newer item.
    try remoteUpdate(presence, rev: 1, items: #""a":{"rev":1,"timestamp":10,"value":0},"b":{"rev":3,"timestamp":20,"value":6}"#)
    // A tombstone (no value property) removes a defined value.
    try remoteUpdate(presence, rev: 4, items: #""a":{"rev":4,"timestamp":30}"#)
    // A tombstone for a key that has no prior value raises no item event and no remoteUpdated.
    try remoteUpdate(presence, rev: 5, items: #""c":{"rev":5,"timestamp":40}"#)

    #expect(
      recorder.values == [
        "updated a 1", "updated b 5", "remoteUpdated [\"a\", \"b\"]",
        "updated b 6", "remoteUpdated [\"b\"]",
        "removed a", "remoteUpdated []",
      ])
    let attendee = try presence.attendees.getAttendee("attendeeId-4")
    let remote = try map.getRemote(attendee)
    #expect(remote.keys == ["b"])
  }

  @Test("items with invalid keys are stored but raise no events and are not returned")
  func invalidKeys() throws {
    let presence = try connected()
    let map = try manager(presence, keyValidator: { !$0.utf16.starts(with: "bad".utf16) })
    let recorder = Recorder<String>()
    map.events.on { event in
      if case .remoteItemUpdated(let data) = event {
        recorder.record(data.key.description)
      }
    }
    try remoteUpdate(presence, rev: 1, items: #""badkey":{"rev":1,"timestamp":10,"value":1}"#)
    #expect(recorder.values.isEmpty)
    let attendee = try presence.attendees.getAttendee("attendeeId-4")
    #expect(try map.getRemote(attendee).size == 0)
  }
}
