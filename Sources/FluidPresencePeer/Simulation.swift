import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidPresence

/// Swift mirror of harness/src/presence/oracle.ts: the same simulated clients, the same driver-owned
/// signal bus and the same trace rows, over FluidPresence. Keep the two in step.

private let startTime: Double = 1_000_000

func object(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
  var value = JSObject<JSONValue>()
  for (key, entry) in entries {
    value[key] = entry
  }
  return .object(value)
}

struct SimulationError: Error {
  let message: String
}

private func memberString(_ value: JSONValue, _ key: JSString) -> JSString? {
  guard case .object(let object) = value, case .string(let string)? = object[key] else {
    return nil
  }
  return string
}

private func memberNumber(_ value: JSONValue, _ key: JSString) -> Double? {
  guard case .object(let object) = value, case .number(let number)? = object[key] else {
    return nil
  }
  return number
}

private func memberBool(_ value: JSONValue, _ key: JSString) -> Bool? {
  guard case .object(let object) = value, case .bool(let bool)? = object[key] else {
    return nil
  }
  return bool
}

private func memberValue(_ value: JSONValue, _ key: JSString) -> JSONValue? {
  guard case .object(let object) = value else {
    return nil
  }
  return object[key]
}

private func hasMember(_ value: JSONValue, _ key: JSString) -> Bool {
  memberValue(value, key) != nil
}

private func memberArray(_ value: JSONValue, _ key: JSString) -> [JSONValue] {
  guard case .array(let array)? = memberValue(value, key) else {
    return []
  }
  return array
}

private final class KnownWorkspace {
  let space: JSString
  let address: JSString
  var types: [(key: JSString, type: JSString)] = []
  let workspace: PresenceStatesImpl

  init(space: JSString, address: JSString, workspace: PresenceStatesImpl) {
    self.space = space
    self.address = address
    self.workspace = workspace
  }
}

private final class Slot {
  let index: Int
  let attendeeId: JSString
  var runtime: SlotRuntime?
  var presence: PresenceManager?
  var connectionCount = 0
  var workspaces = JSMap<JSString, KnownWorkspace>()
  var subscribed = Set<JSString>()
  var armed: [JSString: JSONValue] = [:]

  init(index: Int) {
    self.index = index
    attendeeId = JSString("attendee-\(index)")
  }
}

private struct ServiceMember {
  let connectionId: JSString
  let slot: Int
  let write: Bool
  let interactive: Bool
  let sequenceNumber: Int?
}

private final class SlotRuntime: IEphemeralRuntime {
  var clientId: JSString?
  var joined = false
  let audience = MockAudience()
  let quorum = MockQuorumClients()
  var disconnectedListeners: [() throws -> Void] = []
  let clock: any PresenceClock
  let supportedFeatures: Set<JSString> = ["submit_signals_v2"]
  private let onSubmit: (OutboundPresenceMessage) throws -> Void

  init(clock: any PresenceClock, onSubmit: @escaping (OutboundPresenceMessage) throws -> Void) {
    self.clock = clock
    self.onSubmit = onSubmit
  }

  func getJoinedStatus() -> JoinedStatus { joined ? .joinedForReading : .disconnected }
  func getClientId() -> ClientConnectionId? { clientId }
  func getQuorum() -> any IQuorumClients { quorum }
  func getAudience() -> any IAudience { audience }

  func onDisconnected(_ listener: @escaping () throws -> Void) {
    disconnectedListeners.append(listener)
  }

  func submitSignal(_ message: OutboundPresenceMessage) throws {
    try onSubmit(message)
  }
}

final class Simulation {
  private let scenario: JSONValue
  private let clock: ManualPresenceClock
  private var rows: [JSONValue] = []
  private var slots: [Slot] = []
  private var members: [(JSString, ServiceMember)] = []
  private var eventCounter = 0
  private var quorumCounter = 0
  private let network: [(delay: Double, drop: Bool)]

  init(scenario: JSONValue) throws {
    self.scenario = scenario
    let randoms = try scenario.member("randoms").asArray().map { try $0.asNumber() }
    clock = ManualPresenceClock(start: startTime, randoms: randoms)
    network = try scenario.member("network").asArray().map {
      (try $0.member("delay").asNumber(), try $0.member("drop") == .bool(true))
    }
    let slotCount = try scenario.member("slots").asInt()
    for index in 0..<slotCount {
      slots.append(Slot(index: index))
    }
  }

  func run() throws -> JSONValue {
    clock.onError = { [unowned self] _ in
      rows.append(object([("t", .number(clock.now())), ("error", .string("timer"))]))
    }
    for command in try scenario.member("commands").asArray() {
      let kind = memberString(command, "kind")?.description ?? ""
      do {
        try apply(command, kind: kind)
      } catch {
        rows.append(
          object([
            ("t", .number(clock.now())),
            ("slot", memberNumber(command, "slot").map { .number($0) } ?? .null),
            ("error", .string(JSString(kind))),
          ]))
      }
      if kind != "advance" {
        clock.advance(by: 0)
      }
      rows.append(try snapshot())
    }
    return .array(rows)
  }

  private func slotOf(_ command: JSONValue) throws -> Slot {
    guard let index = memberNumber(command, "slot").flatMap({ Int(exactly: $0) }),
      slots.indices.contains(index)
    else {
      throw SimulationError(message: "bad slot")
    }
    return slots[index]
  }

  private func presenceOf(_ slot: Slot) throws -> PresenceManager {
    guard let presence = slot.presence else {
      throw SimulationError(message: "slot not created")
    }
    return presence
  }

  private func networkEntry(_ destination: Int) throws -> (delay: Double, drop: Bool) {
    guard !network.isEmpty else {
      throw SimulationError(message: "empty network table")
    }
    let entry = network[(eventCounter * 3 + destination * 11) % network.count]
    eventCounter += 1
    return entry
  }

  private func row(_ slot: Slot, _ ev: JSString, _ payload: [(JSString, JSONValue?)]) {
    rows.append(
      object(
        [("t", .number(clock.now())), ("slot", .number(Double(slot.index))), ("ev", .string(ev))]
          + payload))
  }

  private func apply(_ command: JSONValue, kind: String) throws {
    switch kind {
    case "create":
      try create(slotOf(command))
    case "connect":
      try connect(
        slotOf(command), write: memberBool(command, "write") == true,
        interactive: memberBool(command, "interactive") != false)
    case "disconnect":
      try disconnect(slotOf(command))
    case "workspace":
      try registerWorkspace(slotOf(command), command)
    case "arm":
      let slot = try slotOf(command)
      let space = memberString(command, "space") ?? ""
      let address = memberString(command, "address") ?? ""
      slot.armed[JSString("\(space):\(address)")] = command
    case "set":
      let manager = try latestManager(slotOf(command), command)
      try manager.setLocal(memberValue(command, "value") ?? .null)
    case "mapSet":
      let manager = try latestMapManager(slotOf(command), command)
      try manager.local.set(memberString(command, "mapKey") ?? "", memberValue(command, "value") ?? .null)
    case "mapDelete":
      let slot = try slotOf(command)
      let manager = try latestMapManager(slot, command)
      let result = try manager.local.delete(memberString(command, "mapKey") ?? "")
      row(slot, "mapDelete", [("result", .bool(result))])
    case "mapClear":
      try latestMapManager(slotOf(command), command).local.clear()
    case "notify":
      try notify(slotOf(command), command)
    case "controls":
      try controls(slotOf(command), command)
    case "inject":
      try inject(slotOf(command), command)
    case "advance":
      clock.advance(by: memberNumber(command, "ms") ?? 0)
    default:
      throw SimulationError(message: "unknown command \(kind)")
    }
  }

  // MARK: Slots

  private func create(_ slot: Slot) throws {
    guard slot.presence == nil else {
      throw SimulationError(message: "already created")
    }
    let runtime = SlotRuntime(clock: clock) { [unowned self, unowned slot] message in
      try submit(slot, message)
    }
    slot.runtime = runtime
    let presence = try createPresenceManager(runtime: runtime, attendeeId: slot.attendeeId)
    slot.presence = presence
    presence.attendees.events.on { [unowned self, unowned slot] event in
      switch event {
      case .attendeeConnected(let attendee):
        row(slot, "attendeeConnected", [("attendee", .string(attendee.attendeeId))])
      case .attendeeDisconnected(let attendee):
        row(slot, "attendeeDisconnected", [("attendee", .string(attendee.attendeeId))])
      }
    }
    presence.events.on { [unowned self, unowned slot] event in
      guard case .workspaceActivated(let address, let type) = event else {
        return
      }
      row(slot, "workspaceActivated", [("address", .string(address)), ("type", .string(JSString(type.rawValue)))])
      let armedKey = JSString("\(type == .states ? "states" : "notifications"):\(address)")
      if let armed = slot.armed[armedKey] {
        slot.armed[armedKey] = nil
        try registerWorkspace(slot, armed)
      }
    }
  }

  private func clientDetails(write: Bool, interactive: Bool, name: JSString) throws -> IClient {
    try mockClient(write: write, interactive: interactive, name: name)
  }

  // Port of MockEphemeralRuntime.connect with the audience populated from the service's current
  // membership, which is what a real connection receives.
  private func connect(_ slot: Slot, write: Bool, interactive: Bool) throws {
    _ = try presenceOf(slot)
    guard let runtime = slot.runtime else {
      throw SimulationError(message: "slot not created")
    }
    let connectionId = JSString("c\(slot.index).\(slot.connectionCount)")
    slot.connectionCount += 1
    let oldClientId = runtime.clientId
    let sequenceNumber: Int? = write ? 10 * quorumCounter : nil
    if write {
      quorumCounter += 1
    }
    let existing = members.map { $0.1 }
    members.append(
      (
        connectionId,
        ServiceMember(
          connectionId: connectionId, slot: slot.index, write: write, interactive: interactive,
          sequenceNumber: sequenceNumber)
      ))
    let clientObject = try clientDetails(write: write, interactive: interactive, name: slot.attendeeId)

    // Quorum views are reliable and immediate. The joiner's quorum is rebuilt from the service.
    if write, let sequenceNumber {
      for other in slots where other.index != slot.index {
        other.runtime?.quorum.addMember(
          connectionId, mockQuorumMember(client: clientObject, sequenceNumber: sequenceNumber))
      }
    }
    for (staleId, _) in runtime.quorum.getMembers().entries {
      runtime.quorum.removeMember(staleId)
    }
    if write, let sequenceNumber {
      runtime.quorum.addMember(
        connectionId, mockQuorumMember(client: clientObject, sequenceNumber: sequenceNumber))
    }
    for prior in existing where prior.write {
      let priorClient = try clientDetails(
        write: prior.write, interactive: prior.interactive, name: slots[prior.slot].attendeeId)
      runtime.quorum.addMember(
        prior.connectionId,
        mockQuorumMember(client: priorClient, sequenceNumber: prior.sequenceNumber ?? 0))
    }

    let previousMembers = runtime.audience.getMembers()
    runtime.clientId = connectionId
    runtime.joined = true
    for (memberId, _) in previousMembers.entries {
      try runtime.audience.removeMember(memberId)
    }
    for prior in existing where prior.connectionId != oldClientId {
      let priorClient = try clientDetails(
        write: prior.write, interactive: prior.interactive, name: slots[prior.slot].attendeeId)
      try runtime.audience.addMember(prior.connectionId, priorClient)
    }
    try runtime.audience.addMember(connectionId, clientObject)

    for other in slots {
      guard other.index != slot.index, let target = other.runtime else {
        continue
      }
      let entry = try networkEntry(other.index)
      _ = clock.setTimeout(
        {
          if target.joined {
            try target.audience.addMember(connectionId, clientObject)
          }
        }, delay: entry.delay)
    }
  }

  private func disconnect(_ slot: Slot) throws {
    guard let runtime = slot.runtime, runtime.joined, let connectionId = runtime.clientId else {
      throw SimulationError(message: "not connected")
    }
    members.removeAll { $0.0 == connectionId }
    runtime.joined = false
    for listener in runtime.disconnectedListeners {
      try listener()
    }
    for other in slots {
      guard other.index != slot.index, let target = other.runtime else {
        continue
      }
      target.quorum.removeMember(connectionId)
      let entry = try networkEntry(other.index)
      _ = clock.setTimeout(
        {
          if target.joined {
            try target.audience.removeMember(connectionId)
          }
        }, delay: entry.delay)
    }
  }

  // MARK: Signal bus

  /// The driver-owned signal bus. `message` is what presence handed to submitSignal.
  private func submit(_ sender: Slot, _ message: OutboundPresenceMessage) throws {
    let parsed = try JSON.parse(JSON.stringify(message.json))
    rows.append(
      object([("t", .number(clock.now())), ("slot", .number(Double(sender.index))), ("signal", parsed)]))
    guard let senderConnection = sender.runtime?.clientId else {
      throw SimulationError(message: "sender has no connection")
    }
    let target = memberString(parsed, "targetClientId")
    for (_, member) in members {
      if let target, member.connectionId != target {
        continue
      }
      let destination = slots[member.slot]
      let entry = try networkEntry(destination.index)
      if entry.drop {
        continue
      }
      let destinationConnection = member.connectionId
      let type = memberString(parsed, "type") ?? ""
      let content = memberValue(parsed, "content")
      _ = clock.setTimeout(
        { [unowned self] in
          guard let destinationRuntime = destination.runtime, destinationRuntime.joined,
            destinationRuntime.clientId == destinationConnection
          else {
            return
          }
          let inbound = InboundExtensionMessage(
            type: type, content: content, clientId: senderConnection, targetClientId: target)
          do {
            try presenceOf(destination).processSignal(
              addressChain: [], message: inbound, local: senderConnection == destinationConnection)
          } catch {
            rows.append(
              object([
                ("t", .number(clock.now())), ("slot", .number(Double(destination.index))),
                ("error", .string("processSignal")),
              ]))
          }
        }, delay: entry.delay)
    }
  }

  private func inject(_ slot: Slot, _ command: JSONValue) throws {
    guard let message = memberValue(command, "message") else {
      throw SimulationError(message: "inject without message")
    }
    let inbound = InboundExtensionMessage(
      type: memberString(message, "type") ?? "", content: memberValue(message, "content"),
      clientId: memberString(command, "from"))
    let addressChain = memberArray(command, "addressChain").compactMap { value -> JSString? in
      if case .string(let string) = value {
        return string
      }
      return nil
    }
    try presenceOf(slot).processSignal(
      addressChain: addressChain, message: inbound, local: memberBool(command, "local") == true)
  }

  // MARK: Workspaces

  private func isShapedLikeX(_ raw: JSONValue) -> Bool {
    guard case .object(let object) = raw, case .number? = object["x"] else {
      return false
    }
    return true
  }

  private func validator() -> StateSchemaValidator {
    { [unowned self] raw in
      rows.append(object([("t", .number(clock.now())), ("validate", raw)]))
      return isShapedLikeX(raw) ? raw : nil
    }
  }

  private func factory(_ slot: Slot, _ entry: JSONValue) throws -> any ManagerFactory {
    let latency = memberNumber(entry, "latency")
    let settings = latency.map { BroadcastControlSettings(allowableUpdateLatencyMs: $0) }
    let validator = memberBool(entry, "validated") == true ? validator() : nil
    switch memberString(entry, "type")?.description ?? "" {
    case "latest":
      return LatestFactory(
        local: memberValue(entry, "local") ?? .null, settings: settings, validator: validator,
        clock: clock)
    case "latestMap":
      var local: JSObject<JSONValue>?
      if case .object(let object)? = memberValue(entry, "local") {
        local = object
      }
      let keyValidator: KeySchemaValidator? =
        memberBool(entry, "keyValidated") == true ? { !$0.utf16.starts(with: "bad".utf16) } : nil
      return LatestMapFactory(
        local: local, settings: settings, validator: validator, keyValidator: keyValidator,
        clock: clock)
    default:
      var subscriptions: [(name: JSString, listener: NotificationListener)] = []
      for case .string(let name) in memberArray(entry, "subscriptions") {
        subscriptions.append(
          (
            name,
            { [unowned self, unowned slot] attendee, args in
              row(slot, "notification", [("name", .string(name)), ("attendee", .string(attendee.attendeeId)), ("args", .array(args))])
            }
          ))
      }
      return NotificationsFactory(initialSubscriptions: subscriptions)
    }
  }

  private func registerWorkspace(_ slot: Slot, _ command: JSONValue) throws {
    let presence = try presenceOf(slot)
    let space = memberString(command, "space") ?? ""
    let address = memberString(command, "address") ?? ""
    let schemaEntries = memberArray(command, "schema")
    var schema: [(key: JSString, factory: any ManagerFactory)] = []
    for entry in schemaEntries {
      schema.append((memberString(entry, "key") ?? "", try factory(slot, entry)))
    }
    let workspace: PresenceStatesImpl
    if space == "states" {
      let settings = memberNumber(command, "latency").map {
        BroadcastControlSettings(allowableUpdateLatencyMs: $0)
      }
      workspace = try presence.states.getWorkspace(address, WorkspaceSchema(schema), settings: settings)
    } else {
      workspace = try presence.notifications.getWorkspace(address, WorkspaceSchema(schema))
    }
    let id = JSString("\(space):\(address)")
    let known = slot.workspaces.get(id) ?? KnownWorkspace(space: space, address: address, workspace: workspace)
    for entry in schemaEntries {
      let key = memberString(entry, "key") ?? ""
      if !known.types.contains(where: { $0.key == key }) {
        known.types.append((key, memberString(entry, "type") ?? ""))
      }
    }
    slot.workspaces.set(id, known)
    for entry in schemaEntries {
      try subscribe(slot, known, entry)
    }
  }

  private func metadataFields(_ metadata: LatestMetadata) -> [(JSString, JSONValue?)] {
    [("rev", .number(metadata.revision)), ("ts", metadata.timestamp.map { .number($0) } ?? .null)]
  }

  private func subscribe(_ slot: Slot, _ known: KnownWorkspace, _ entry: JSONValue) throws {
    let key = memberString(entry, "key") ?? ""
    let id = JSString("\(known.space):\(known.address):\(key)")
    if slot.subscribed.contains(id) {
      return
    }
    slot.subscribed.insert(id)
    let base: [(JSString, JSONValue?)] = [("address", .string(known.address)), ("key", .string(key))]
    switch memberString(entry, "type")?.description ?? "" {
    case "latest":
      let latest = try known.workspace.latest(key)
      latest.events.on { [unowned self, unowned slot] event in
        switch event {
        case .localUpdated(let value):
          row(slot, "localUpdated", base + [("value", value)])
        case .remoteUpdated(let data):
          row(
            slot, "remoteUpdated",
            base + [("attendee", .string(data.attendee.attendeeId)), ("value", data.value.resolve())]
              + metadataFields(data.metadata))
        }
      }
    case "latestMap":
      let map = try known.workspace.latestMap(key)
      map.events.on { [unowned self, unowned slot] event in
        switch event {
        case .localItemUpdated(let mapKey, let value):
          row(slot, "localItemUpdated", base + [("mapKey", .string(mapKey)), ("value", value)])
        case .localItemRemoved(let mapKey):
          row(slot, "localItemRemoved", base + [("mapKey", .string(mapKey))])
        case .remoteItemUpdated(let data):
          row(
            slot, "remoteItemUpdated",
            base + [
              ("attendee", .string(data.attendee.attendeeId)), ("mapKey", .string(data.key)),
              ("value", data.value.resolve()),
            ] + metadataFields(data.metadata))
        case .remoteItemRemoved(let data):
          row(
            slot, "remoteItemRemoved",
            base + [("attendee", .string(data.attendee.attendeeId)), ("mapKey", .string(data.key))]
              + metadataFields(data.metadata))
        case .remoteUpdated(let data):
          let items = data.items.entries.map { itemKey, item in
            object(
              [("mapKey", .string(itemKey)), ("value", item.value.resolve())]
                + metadataFields(item.metadata))
          }
          row(
            slot, "remoteUpdated",
            base + [("attendee", .string(data.attendee.attendeeId)), ("items", .array(items))])
        }
      }
    default:
      let notifications = try known.workspace.notifications(key)
      notifications.events.on { [unowned self, unowned slot] event in
        guard case .unattendedNotification(let name, let sender, let content) = event else {
          return
        }
        row(
          slot, "unattended",
          base + [("name", .string(name)), ("attendee", .string(sender.attendeeId)), ("args", .array(content))])
      }
    }
  }

  private func knownWorkspace(_ slot: Slot, _ command: JSONValue) throws -> KnownWorkspace {
    let space = memberString(command, "space") ?? ""
    let address = memberString(command, "address") ?? ""
    guard let known = slot.workspaces.get(JSString("\(space):\(address)")) else {
      throw SimulationError(message: "workspace not registered")
    }
    return known
  }

  private func latestManager(_ slot: Slot, _ command: JSONValue) throws -> LatestValueManagerImpl {
    try knownWorkspace(slot, command).workspace.latest(memberString(command, "key") ?? "")
  }

  private func latestMapManager(_ slot: Slot, _ command: JSONValue) throws -> LatestMapValueManagerImpl {
    try knownWorkspace(slot, command).workspace.latestMap(memberString(command, "key") ?? "")
  }

  private func notify(_ slot: Slot, _ command: JSONValue) throws {
    let known = try knownWorkspace(slot, command)
    let manager = try known.workspace.notifications(memberString(command, "key") ?? "")
    let name = memberString(command, "name") ?? ""
    let args = memberArray(command, "args")
    guard let target = memberNumber(command, "target") else {
      try manager.emit.broadcast(name, args)
      return
    }
    let attendee = try presenceOf(slot).attendees.getAttendee(JSString("attendee-\(Int(target))"))
    try manager.emit.unicast(name, attendee, args)
  }

  private func controls(_ slot: Slot, _ command: JSONValue) throws {
    let known = try knownWorkspace(slot, command)
    if let key = memberString(command, "key") {
      let manager = known.workspace.manager(key)
      let controls: OptionalBroadcastControl
      if let latest = manager as? LatestValueManagerImpl {
        controls = latest.controls
      } else if let map = manager as? LatestMapValueManagerImpl {
        controls = map.controls
      } else {
        // A notifications manager has no `controls`; setting a property on it throws in TS.
        throw SimulationError(message: "no controls")
      }
      if hasMember(command, "latency") {
        controls.allowableUpdateLatencyMs = memberNumber(command, "latency")
      }
      if hasMember(command, "refresh") {
        try controls.setForcedRefreshIntervalMs(memberNumber(command, "refresh"))
      }
      return
    }
    if hasMember(command, "latency") {
      known.workspace.controls.setAllowableUpdateLatencyMs(memberNumber(command, "latency"))
    }
    if hasMember(command, "refresh") {
      try known.workspace.controls.setForcedRefreshIntervalMs(memberNumber(command, "refresh"))
    }
  }

  // MARK: Snapshot

  /// Everything an application can observe about every created slot.
  private func snapshot() throws -> JSONValue {
    var states: [JSONValue] = []
    for slot in slots {
      if let presence = slot.presence {
        states.append(try snapshotSlot(slot, presence))
      } else {
        states.append(.null)
      }
    }
    return object([("t", .number(clock.now())), ("state", .array(states))])
  }

  private func attempt(_ body: () throws -> JSONValue) -> JSONValue {
    do {
      return try body()
    } catch {
      return .string("error")
    }
  }

  private func snapshotSlot(_ slot: Slot, _ presence: PresenceManager) throws -> JSONValue {
    let attendees = presence.attendees.getAttendees()
    var workspaces: [JSONValue] = []
    for (_, known) in slot.workspaces.entries {
      var managers: [JSONValue] = []
      for (key, type) in known.types {
        var fields: [(JSString, JSONValue?)] = [("key", .string(key))]
        fields += try snapshotManager(type, known.workspace, key, attendees)
        managers.append(object(fields))
      }
      workspaces.append(
        object([
          ("space", .string(known.space)), ("address", .string(known.address)),
          ("managers", .array(managers)),
        ]))
    }
    return object([
      ("myself", .string(presence.attendees.getMyself().attendeeId)),
      (
        "attendees",
        .array(
          attendees.map { attendee in
            object([
              ("id", .string(attendee.attendeeId)),
              ("status", .string(JSString(attendee.getConnectionStatus().rawValue))),
              ("connection", attempt { .string(try attendee.getConnectionId()) }),
            ])
          })
      ),
      ("workspaces", .array(workspaces)),
    ])
  }

  private func snapshotManager(
    _ type: JSString, _ workspace: PresenceStatesImpl, _ key: JSString, _ attendees: [any Attendee]
  ) throws -> [(JSString, JSONValue?)] {
    if type == "latest" {
      let latest = try workspace.latest(key)
      return [
        ("local", latest.local),
        (
          "remotes",
          attempt {
            .array(
              try latest.getRemotes().map { remote in
                object(
                  [("attendee", .string(remote.attendee.attendeeId)), ("value", remote.value.resolve())]
                    + metadataFields(remote.metadata))
              })
          }
        ),
        (
          "stateAttendees",
          attempt { .array(try latest.getStateAttendees().map { .string($0.attendeeId) }) }
        ),
        (
          "byAttendee",
          .array(
            attendees.map { attendee in
              attempt {
                let remote = try latest.getRemote(attendee)
                return object([("value", remote.value.resolve())] + metadataFields(remote.metadata))
              }
            })
        ),
      ]
    }
    if type == "latestMap" {
      let map = try workspace.latestMap(key)
      func itemRows(_ items: JSMap<JSString, LatestData>) -> JSONValue {
        .array(
          items.entries.map { itemKey, item in
            object(
              [("mapKey", .string(itemKey)), ("value", item.value.resolve())]
                + metadataFields(item.metadata))
          })
      }
      return [
        ("size", .number(Double(map.local.size))),
        (
          "local",
          .array(
            map.local.keys().map { mapKey in
              .array([.string(mapKey), map.local.get(mapKey) ?? .null])
            })
        ),
        (
          "remotes",
          attempt {
            .array(
              try map.getRemotes().map { remote in
                object([("attendee", .string(remote.attendee.attendeeId)), ("items", itemRows(remote.items))])
              })
          }
        ),
        (
          "stateAttendees",
          attempt { .array(try map.getStateAttendees().map { .string($0.attendeeId) }) }
        ),
        (
          "byAttendee",
          .array(attendees.map { attendee in attempt { itemRows(try map.getRemote(attendee)) } })
        ),
      ]
    }
    return []
  }
}
