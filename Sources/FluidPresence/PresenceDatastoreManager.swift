import FluidDriverDefinitions
import FluidJS

/// Ports presence-runtime/src/runtime/presenceDatastoreManager.ts.

/// Delays used for broadcasting join responses to clients.
public enum BroadcastJoinResponseDelaysMs {
  /// The delay before a join response is sent to any client, to accumulate other join response
  /// requests and reduce network traffic.
  public static let namedResponder: Double = 200

  /// The additional delay a backup responder waits before sending a join response, to allow
  /// others to respond first.
  public static let backupResponderIncrement: Double = 40
}

/// `PresenceDatastoreManager`: the contract the presence manager uses.
protocol PresenceDatastoreManager: AnyObject {
  func joinSession(_ clientId: ClientConnectionId, alternateProvider: ClientConnectionId?) throws
  func onDisconnected()
  func getWorkspace(
    _ internalWorkspaceAddress: JSString, requestedContent: WorkspaceSchema,
    controls: BroadcastControlSettings?
  ) throws -> PresenceStatesImpl
  func processSignal(
    _ message: InboundExtensionMessage, clientId: ClientConnectionId, local: Bool, optional: Bool
  ) throws
}

/// The combined contents of all queued updates: `"sendAll"` when a full broadcast is pending.
private enum QueuedData {
  case sendAll
  case partial(GeneralDatastoreMessageContent)
}

/// How this client came to have a complete snapshot (only when not using targeted join responses).
private enum ReasonForCompleteSnapshot {
  /// No other audience members were detected at join.
  case alone
  /// Another client has responded to our join request.
  case joinResponse
  /// All others have requested a response from us.
  case fullRequests
}

/// An outstanding broadcast (join response) request. `responseOrder` is `nil` for a named responder.
private struct BroadcastRequest {
  var deadlineTime: Double
  var responseOrder: Double?
}

/// Interactive audience members other than self, in audience order.
private struct AudienceInformation {
  var selfPresent: Bool
  var all: [ClientConnectionId]
  var writers: [ClientConnectionId]
}

/// `mergeGeneralDatastoreMessageContent`: merges `newData` into the queued content, queued entries
/// winning ties because only a greater revision replaces a leaf. Local values need no time shift.
private func mergeGeneralDatastoreMessageContent(
  base: GeneralDatastoreMessageContent?, newData: GeneralDatastoreMessageContent
) -> GeneralDatastoreMessageContent {
  // This function-local "datastore" holds the merged message data.
  var queueDatastore = base ?? GeneralDatastoreMessageContent()

  // Iterate over the current message data; individual items are workspaces.
  for (workspaceName, workspaceData) in newData.entries {
    var mergedData = queueDatastore[workspaceName] ?? WorkspaceMessageContent()

    // Iterate over each value manager and its data, merging it as needed.
    for (valueManagerKey, valueManagerValue) in workspaceData.entries {
      for (attendeeId, value) in valueManagerValue.entries {
        var mergeObject = mergedData[valueManagerKey] ?? JSObject<ValueDirectoryOrState>()
        let oldData = mergeObject[attendeeId]
        mergeObject[attendeeId] = mergeValueDirectory(base: oldData, update: value, timeDelta: 0)
        mergedData[valueManagerKey] = mergeObject
      }
    }

    queueDatastore[workspaceName] = mergedData
  }
  return queueDatastore
}

/// The workspace-facing side of the datastore manager: the `localUpdate` closure and presence
/// handle that TS `getWorkspace` passes to `createPresenceStates`.
private final class WorkspaceRuntime: PresenceRuntime {
  private unowned let manager: PresenceDatastoreManagerImpl
  private let address: JSString
  let presence: any Presence
  let attendeeId: AttendeeId

  init(
    manager: PresenceDatastoreManagerImpl, address: JSString, presence: any Presence,
    attendeeId: AttendeeId
  ) {
    self.manager = manager
    self.address = address
    self.presence = presence
    self.attendeeId = attendeeId
  }

  var clock: any PresenceClock {
    manager.clock
  }

  func localUpdate(
    _ states: JSObject<ValueDirectoryOrState>, options: RuntimeLocalUpdateOptions
  ) throws {
    try manager.localUpdate(address: address, states: states, options: options)
  }
}

/// Ports `PresenceDatastoreManagerImpl`: manages the singleton datastore for all presence.
final class PresenceDatastoreManagerImpl: PresenceDatastoreManager {
  private let systemDatastore: SystemWorkspaceDatastore
  private var workspaceDatastores = JSObject<ValueElementMap>()
  private var averageLatency: Double = 0
  private var returnedMessages: Double = 0
  private let sendMessageTimer: TimerManager
  private var workspaces = JSMap<JSString, AnyWorkspaceEntry>()
  private let targetedSignalSupport: Bool
  private var reasonForCompleteSnapshot: ReasonForCompleteSnapshot?

  /// Outstanding broadcast (join response) requests, by requestor connection.
  private var broadcastRequests = JSMap<ClientConnectionId, BroadcastRequest>()
  private let broadcastRequestsTimer: TimerManager

  private let attendeeId: AttendeeId
  private let runtime: any IEphemeralRuntime
  private let presenceEvents: Emitter<PresenceEvent>
  private let presence: any Presence

  /// The combined contents of all queued updates, or `nil` when nothing is queued.
  private var queuedData: QueuedData?

  let clock: any PresenceClock

  init(
    attendeeId: AttendeeId,
    runtime: any IEphemeralRuntime,
    events: Emitter<PresenceEvent>,
    presence: any Presence,
    systemWorkspaceDatastore: SystemWorkspaceDatastore,
    systemWorkspace: AnyWorkspaceEntry
  ) {
    self.attendeeId = attendeeId
    self.runtime = runtime
    presenceEvents = events
    self.presence = presence
    systemDatastore = systemWorkspaceDatastore
    clock = runtime.clock
    sendMessageTimer = TimerManager(clock: runtime.clock)
    broadcastRequestsTimer = TimerManager(clock: runtime.clock)
    targetedSignalSupport = runtime.supportedFeatures.contains("submit_signals_v2")
    workspaces.set(systemWorkspaceAddress, systemWorkspace)
    // If an audience member is removed, they won't need a broadcast response.
    runtime.getAudience().onRemoveMember { [unowned self] clientId in
      self.broadcastRequests.delete(clientId)
    }
  }

  private func getAudienceInformation(selfClientId: ClientConnectionId) -> AudienceInformation {
    let members = runtime.getAudience().getMembers()
    var all: [ClientConnectionId] = []
    var writers: [ClientConnectionId] = []
    let selfPresent = members.has(selfClientId)
    // Gather interactive client IDs, leaving out self.
    for (id, client) in members.entries where id != selfClientId {
      if client.details.capabilities.interactive {
        all.append(id)
        if client.mode == .write {
          writers.append(id)
        }
      }
    }
    return AudienceInformation(selfPresent: selfPresent, all: all, writers: writers)
  }

  func joinSession(_ selfClientId: ClientConnectionId, alternateProvider: ClientConnectionId?) throws {
    // Before broadcasting the join message, check that there is at least one audience member
    // present (self or another). Lack of anyone likely means this client is very freshly joined and
    // has not received any Join Signals from the service yet.
    let audienceInformation = getAudienceInformation(selfClientId: selfClientId)

    if audienceInformation.selfPresent {
      if audienceInformation.all.isEmpty {
        // If there aren't any members connected except self, this client must have complete
        // information. Continue sending ClientJoin in case audience information is inaccurate.
        reasonForCompleteSnapshot = .alone
      }
    } else {
      // When self is not represented the audience is unreliable, especially during a reconnect.
      // An alternateProvider is expected.
      try assertPresence(alternateProvider != nil, "0xcba")
    }

    // Select primary update providers: write members if any, then fall back to read-only members.
    var updateProviders =
      audienceInformation.writers.isEmpty ? audienceInformation.all : audienceInformation.writers
    // Limit to three providers to prevent flooding the network. If none respond, others present
    // will (should) after a delay.
    if updateProviders.count > 3 {
      updateProviders = Array(updateProviders.prefix(3))
    } else if updateProviders.isEmpty, let alternateProvider {
      updateProviders.append(alternateProvider)
    }
    try runtime.submitSignal(
      .clientJoin(
        sendTimestamp: clock.now(),
        avgLatency: averageLatency,
        data: stripValidationMetadata(),
        updateProviders: updateProviders))
  }

  func onDisconnected() {
    reasonForCompleteSnapshot = nil
  }

  func getWorkspace(
    _ internalWorkspaceAddress: JSString, requestedContent: WorkspaceSchema,
    controls: BroadcastControlSettings?
  ) throws -> PresenceStatesImpl {
    if let existing = workspaces.get(internalWorkspaceAddress) {
      return try existing.internal.ensureContent(requestedContent, controls: controls)
    }

    let workspaceDatastore = datastore(for: internalWorkspaceAddress)
    let workspaceRuntime = WorkspaceRuntime(
      manager: self, address: internalWorkspaceAddress, presence: presence, attendeeId: attendeeId)
    let entry = try createPresenceStates(
      runtime: workspaceRuntime, datastore: workspaceDatastore, initialContent: requestedContent,
      controls: controls)
    workspaces.set(internalWorkspaceAddress, entry)
    guard let publicWorkspace = entry.publicWorkspace else {
      throw PresenceError.failed("workspace without public view")
    }
    return publicWorkspace
  }

  /// `this.datastore[address] ??= {}`.
  private func datastore(for address: JSString) -> ValueElementMap {
    if let existing = workspaceDatastores[address] {
      return existing
    }
    let created = ValueElementMap()
    workspaceDatastores[address] = created
    return created
  }

  /// The `localUpdate` closure of TS `getWorkspace`.
  fileprivate func localUpdate(
    address: JSString, states: JSObject<ValueDirectoryOrState>, options: RuntimeLocalUpdateOptions
  ) throws {
    // Check for connectivity before sending updates.
    if runtime.getJoinedStatus() == .disconnected {
      return
    }

    var updates = WorkspaceMessageContent()
    for (key, value) in states.entries {
      var byAttendee = JSObject<ValueDirectoryOrState>()
      byAttendee[attendeeId] = value
      updates[key] = byAttendee
    }

    var data = GeneralDatastoreMessageContent()
    data[address] = updates
    try enqueueMessage(.partial(data), options: options)
  }

  /// Enqueues a new message to be sent. The message may be queued or sent immediately depending on
  /// the state of the send timer, other messages in the queue and the configured allowed latency.
  private func enqueueMessage(_ data: QueuedData, options: RuntimeLocalUpdateOptions) throws {
    var alreadySendAll = false
    if case .sendAll? = queuedData {
      alreadySendAll = true
    }
    if !alreadySendAll {
      switch data {
      case .sendAll:
        queuedData = .sendAll
      case .partial(let newData):
        // Merging the message with any queued messages effectively queues the message.
        var base: GeneralDatastoreMessageContent?
        if case .partial(let queued)? = queuedData {
          base = queued
        }
        queuedData = .partial(mergeGeneralDatastoreMessageContent(base: base, newData: newData))
      }
    }

    let now = clock.now()
    let thisMessageDeadline = now + options.allowableUpdateLatencyMs

    // If the timer has not expired and this message's deadline is not earlier than the timer's
    // expiry, the timer will fire and cover this update.
    if !sendMessageTimer.hasExpired() && thisMessageDeadline >= sendMessageTimer.expireTime {
      return
    }

    // Either send immediately, or schedule a timer to fire at the send deadline.
    let timeoutInMs = thisMessageDeadline - now
    if timeoutInMs > 0 {
      sendMessageTimer.setTimeout({ [unowned self] in try self.sendQueuedMessage() }, delay: timeoutInMs)
    } else {
      try sendQueuedMessage()
    }
  }

  /// Sends any queued signal immediately. Does nothing if no message is queued.
  private func sendQueuedMessage() throws {
    sendMessageTimer.clearTimeout()

    guard let queued = queuedData else {
      return
    }

    // Check for connectivity before sending updates.
    if runtime.getJoinedStatus() == .disconnected {
      // Clear the queued data since we're disconnected, so messages do not queue indefinitely.
      queuedData = nil
      return
    }

    let queuedContent: GeneralDatastoreMessageContent
    switch queued {
    case .sendAll:
      try broadcastAllKnownState()
      return
    case .partial(let content):
      queuedContent = content
    }

    let clientConnectionId = runtime.getClientId()
    try assertPresence(clientConnectionId != nil, "0xa59")
    guard let clientConnectionId else {
      return
    }
    // When connected, `clientToSessionId` must always have the current connection entry.
    let currentClientToSessionValueState = systemDatastore.clientToSessionId[clientConnectionId]
    try assertPresence(currentClientToSessionValueState != nil, "0xcbb")
    guard let currentClientToSessionValueState else {
      return
    }

    // Always send the current connection mapping for some resiliency against lost signals: the
    // client session ID found in `updates` is always represented in the system workspace of
    // recipient clients.
    var mapping = JSObject<JSONValue>()
    mapping[clientConnectionId] = currentClientToSessionValueState.json
    var system = JSObject<JSONValue>()
    system["clientToSessionId"] = .object(mapping)
    var data = JSObject<JSONValue>()
    data[systemWorkspaceAddress] = .object(system)
    for (address, workspaceContent) in queuedContent.entries {
      data[address] = Self.json(of: workspaceContent)
    }

    let message = OutboundPresenceMessage.datastoreUpdate(
      sendTimestamp: clock.now(), avgLatency: averageLatency, isComplete: false,
      data: .object(data), joinResponseFor: nil)
    queuedData = nil
    try runtime.submitSignal(message)
  }

  private static func json(of workspaceContent: WorkspaceMessageContent) -> JSONValue {
    var workspace = JSObject<JSONValue>()
    for (stateName, byAttendee) in workspaceContent.entries {
      var record = JSObject<JSONValue>()
      for (attendeeId, value) in byAttendee.entries {
        record[attendeeId] = value.json
      }
      workspace[stateName] = .object(record)
    }
    return .object(workspace)
  }

  /// Recursively strips validation metadata (`validatedValue`) from the datastore before
  /// broadcasting, so it does not leak into signals sent to other clients.
  private func stripValidationMetadata() -> JSONValue {
    var messageContent = JSObject<JSONValue>()
    messageContent[systemWorkspaceAddress] = .object(systemDatastoreObject())

    for (workspaceAddress, workspace) in workspaceDatastores.entries {
      var workspaceData = JSObject<JSONValue>()
      for (stateName, clientRecord) in workspace.records.entries {
        var cleanClientRecord = JSObject<JSONValue>()
        for (attendeeId, valueData) in clientRecord.values.entries {
          cleanClientRecord[attendeeId] = stripValidationFromValueData(valueData).json
        }
        workspaceData[stateName] = .object(cleanClientRecord)
      }
      messageContent[workspaceAddress] = .object(workspaceData)
    }

    return .object(messageContent)
  }

  private func systemDatastoreObject() -> JSObject<JSONValue> {
    guard case .object(let object) = systemDatastore.json else {
      return JSObject()
    }
    return object
  }

  /// Strips validation metadata from one value entry. A directory is shallow-copied, but its
  /// `items` object is shared with the original, so the stripped items replace the original's.
  private func stripValidationFromValueData(_ valueDataIn: ValueDirectoryOrState)
    -> ValueDirectoryOrState
  {
    switch valueDataIn {
    case .directory(let directory):
      let copy = ValueDirectory(rev: directory.rev, items: directory.items)
      for (key, item) in directory.items.entries {
        directory.items[key] = stripValidationFromValueData(item)
      }
      copy.items = directory.items
      return .directory(copy)
    case .state(let state):
      let copy = state.copy()
      copy.validated = nil
      return .state(copy)
    }
  }

  private func broadcastAllKnownState() throws {
    let data = stripValidationMetadata()
    var joinResponseFor: [ClientConnectionId]?
    if broadcastRequests.size > 0 {
      joinResponseFor = broadcastRequests.keys
      broadcastRequests.clear()
    }

    // This broadcast satisfies all requests; clear any remaining timers.
    broadcastRequestsTimer.clearTimeout()
    sendMessageTimer.clearTimeout()

    try runtime.submitSignal(
      .datastoreUpdate(
        sendTimestamp: clock.now(), avgLatency: averageLatency, isComplete: true, data: data,
        joinResponseFor: joinResponseFor))

    // Sending all must account for anything queued before.
    queuedData = nil
  }

  func processSignal(
    _ message: InboundExtensionMessage, clientId: ClientConnectionId, local: Bool, optional: Bool
  ) throws {
    let received = clock.now()
    guard let presenceMessage = try InboundPresenceMessage(message) else {
      try assertPresence(optional, "0xcbc")
      return
    }

    if local {
      // `Pres:Ack` is a known type with no handling: its content has no `sendTimestamp`, so the
      // delivery delta is NaN and the average latency is contaminated (specs/presence.md).
      let sendTimestamp: Double
      switch presenceMessage {
      case .join(let content): sendTimestamp = content.sendTimestamp
      case .update(let content): sendTimestamp = content.sendTimestamp
      case .acknowledgement: sendTimestamp = .nan
      }
      let deliveryDelta = received - sendTimestamp
      // Limit returnedMessages to 256 so the newest message always contributes at least 1/256th.
      returnedMessages = min(returnedMessages + 1, 256)
      averageLatency = (averageLatency * (returnedMessages - 1) + deliveryDelta) / returnedMessages
      return
    }

    var postUpdateActions: [PostUpdateAction] = []
    let data: JSObject<JSONValue>
    let timeModifier: Double

    switch presenceMessage {
    case .acknowledgement:
      // A remote Ack reaches `Object.entries(message.content.data)` with `data` undefined, which
      // throws in TS. Nothing was changed before that point.
      throw PresenceError.failed("Cannot convert undefined or null to object")

    case .join(let content):
      timeModifier = received - (averageLatency + content.avgLatency + content.sendTimestamp)
      data = content.data
      // It is possible for some signals to come in while the client is not connected. We can't
      // respond to the join request then; we make our own Join request once connected.
      if runtime.getJoinedStatus() != .disconnected {
        try prepareJoinResponse(updateProviders: content.updateProviders, requestor: clientId)
      }
    // It is okay to continue processing the contained updates even if not connected.

    case .update(let content):
      timeModifier = received - (averageLatency + content.avgLatency + content.sendTimestamp)
      data = content.data
      // Update join response requests that are now satisfied.
      if let joinResponseFor = content.joinResponseFor {
        let selfClientId = runtime.getClientId()
        try assertPresence(selfClientId != nil, "0xcbd")
        guard let selfClientId else {
          return
        }

        var justGainedCompleteSnapshot = false
        if joinResponseFor.contains(selfClientId) {
          // `alone` means no response was expected (a cautionary ClientJoin reached an audience
          // member that was unknown). Otherwise, as the intended recipient, this client's
          // knowledge is now complete.
          if reasonForCompleteSnapshot == nil {
            justGainedCompleteSnapshot = true
          }
          reasonForCompleteSnapshot = .joinResponse
        }
        if broadcastRequests.size > 0 {
          for responseFor in joinResponseFor {
            broadcastRequests.delete(responseFor)
          }
          if broadcastRequests.size == 0 {
            // If no more requests are pending, clear any timer.
            broadcastRequestsTimer.clearTimeout()
          } else if justGainedCompleteSnapshot {
            // May or may not be time to respond to remaining requests. Clear the timer and
            // recheck after processing.
            broadcastRequestsTimer.clearTimeout()
            postUpdateActions.append { [unowned self] in
              try self.sendJoinResponseIfStillNeeded()
            }
          }
        }
      }

      // If the message requests an acknowledgement, send a targeted acknowledgement to the requestor.
      if let acknowledgementId = content.acknowledgementId {
        try assertPresence(targetedSignalSupport, "0xcbe")
        try runtime.submitSignal(.acknowledgement(id: acknowledgementId, targetClientId: clientId))
      }
    }

    // Handle activation of unregistered workspaces before processing updates.
    for (workspaceAddress, _) in data.entries {
      // Skip a workspace that is registered or has been seen before.
      if workspaces.has(workspaceAddress) || workspaceDatastores[workspaceAddress] != nil {
        continue
      }

      // Separate the internal type prefix from the public workspace address.
      guard let (prefix, publicWorkspaceAddress) = Self.splitInternalWorkspaceAddress(workspaceAddress)
      else {
        continue
      }

      let internalWorkspaceType: InternalWorkspaceType
      switch prefix {
      case 0x73: internalWorkspaceType = .states
      case 0x6E: internalWorkspaceType = .notifications
      default: internalWorkspaceType = .unknown
      }

      try presenceEvents.emit(.workspaceActivated(publicWorkspaceAddress, internalWorkspaceType))
    }

    // While the system workspace is processed here too, it is declared as conforming to the
    // general schema.
    for (workspaceAddress, remoteDatastore) in data.entries {
      // Direct to the appropriate presence workspace, if present.
      if let workspace = workspaces.get(workspaceAddress) {
        postUpdateActions.append(
          contentsOf: try workspace.internal.processUpdate(
            received: received, timeModifier: timeModifier, remoteDatastore: remoteDatastore,
            senderConnectionId: clientId))
      } else {
        // All broadcast state is kept even if not currently registered, unless a value notes
        // itself to be ignored.
        let workspaceDatastore = datastore(for: workspaceAddress)
        for (key, remoteAllKnownState) in try remoteDatastore.asObject().entries {
          try mergeUntrackedDatastore(
            key: key, remoteAllKnownState: remoteAllKnownState, datastore: workspaceDatastore,
            timeModifier: timeModifier)
        }
      }
    }

    for action in postUpdateActions {
      try action()
    }
  }

  /// `/^([^:]):([^:]+:.+)$/` over UTF-16 code units: one non-colon unit, a colon, a non-empty
  /// colon-free run, a colon, then a non-empty remainder without line terminators. Returns the
  /// prefix unit and the remainder after the first colon.
  private static func splitInternalWorkspaceAddress(_ address: JSString) -> (UInt16, JSString)? {
    let units = address.utf16
    guard units.count >= 5, units[0] != 0x3A, units[1] == 0x3A else {
      return nil
    }
    var secondColon: Int?
    for index in 2..<units.count where units[index] == 0x3A {
      secondColon = index
      break
    }
    guard let secondColon, secondColon > 2, secondColon < units.count - 1 else {
      return nil
    }
    for unit in units[(secondColon + 1)...] where unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 {
      return nil
    }
    return (units[0], JSString(utf16: ContiguousArray(units[2...])))
  }

  /// Broadcasts a join response (complete datastore update message) if there is an outstanding
  /// join response request.
  private func sendJoinResponseIfStillNeeded() throws {
    // Make sure we are currently connected and a broadcast is still needed.
    if runtime.getJoinedStatus() != .disconnected && broadcastRequests.size > 0 {
      // Confirm that, of the remaining requests, now is the time to respond.
      let now = clock.now()
      var minResponseTime = Double.infinity
      for (_, request) in broadcastRequests.entries {
        minResponseTime = min(minResponseTime, request.deadlineTime)
      }
      if minResponseTime <= now {
        if reasonForCompleteSnapshot != nil {
          try broadcastAllKnownState()
        }
      } else {
        // No response needed yet: schedule a later attempt.
        broadcastRequestsTimer.setTimeout(
          { [unowned self] in try self.sendJoinResponseIfStillNeeded() },
          delay: minResponseTime - now)
      }
    }
  }

  /// Handles responding to another client joining the session. `updateProviders` are the
  /// connection IDs the requestor selected to provide the response.
  private func prepareJoinResponse(
    updateProviders: [ClientConnectionId], requestor: ClientConnectionId
  ) throws {
    // We must be connected to receive this message, so the client ID is defined.
    guard let selfClientId = runtime.getClientId() else {
      throw PresenceError.failed("Join request processed without a client ID")
    }
    var joinResponseDelayMs = BroadcastJoinResponseDelaysMs.namedResponder
    var relativeResponseOrder: Double?
    if !updateProviders.contains(selfClientId) {
      // Schedule a broadcast to the new client after a delay, only sent if another broadcast
      // satisfying the request hasn't been seen in the meantime. The delay is based on the
      // position in the quorum list; it does not have to be stable across clients.
      let quorumMembers = runtime.getQuorum().getMembers()
      if let selfMember = quorumMembers.get(selfClientId) {
        // Compute the order of quorum join (indicated by sequenceNumber).
        let selfSequenceNumber = try ISequencedClient(json: selfMember).sequenceNumber
        var order: Double = 0
        for (_, member) in quorumMembers.entries {
          let sequenced = try ISequencedClient(json: member)
          if sequenced.sequenceNumber < selfSequenceNumber && sequenced.client.details.capabilities.interactive {
            order += 1
          }
        }
        relativeResponseOrder = order
      } else {
        // Order of past quorum members plus an arbitrary additional offset up to 10.
        var possibleQuorumRespondents: Double = 0
        for (_, member) in quorumMembers.entries {
          if try ISequencedClient(json: member).client.details.capabilities.interactive {
            possibleQuorumRespondents += 1
          }
        }
        relativeResponseOrder = possibleQuorumRespondents + clock.random() * 10
      }
      // When not named to provide the update, wait an additional amount of time for those named or
      // others to respond.
      joinResponseDelayMs +=
        BroadcastJoinResponseDelaysMs.backupResponderIncrement
        * (3 * Double(updateProviders.count) + (relativeResponseOrder ?? 0))
    }

    // Add the requestor to the list of clients that will receive the broadcast.
    let deadlineTime = clock.now() + joinResponseDelayMs
    broadcastRequests.set(
      requestor, BroadcastRequest(deadlineTime: deadlineTime, responseOrder: relativeResponseOrder))

    if reasonForCompleteSnapshot == nil {
      // If the requestor count meets or exceeds the count of other audience members, we
      // effectively have a complete snapshot (once the current message is processed).
      let audienceInformation = getAudienceInformation(selfClientId: selfClientId)
      // The self-present check helps ensure the audience information is accurate.
      if audienceInformation.selfPresent && broadcastRequests.size >= audienceInformation.all.count {
        // No action is taken here; the actions below are delayed.
        reasonForCompleteSnapshot = .fullRequests
      }
    }

    // Check if capable of a full primary response. If requested to provide a primary response but
    // there is no complete snapshot yet, delay a full response until there is one; in the
    // meantime partial updates are sent as usual.
    if reasonForCompleteSnapshot != nil && updateProviders.contains(selfClientId) {
      // Use the regular message queue to handle timing of the broadcast. Any more immediate
      // broadcast accelerates the response time.
      try enqueueMessage(
        .sendAll, options: RuntimeLocalUpdateOptions(allowableUpdateLatencyMs: joinResponseDelayMs))
    } else if broadcastRequestsTimer.hasExpired() || deadlineTime < broadcastRequestsTimer.expireTime {
      // No timer is scheduled to send a join response within this request's deadline: set or
      // update the timer.
      broadcastRequestsTimer.setTimeout(
        { [unowned self] in try self.sendJoinResponseIfStillNeeded() }, delay: joinResponseDelayMs)
    }
  }
}
