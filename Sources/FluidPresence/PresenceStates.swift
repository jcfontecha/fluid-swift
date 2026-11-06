import FluidJS

/// Ports presence-runtime/src/workspace/presenceStates.ts.

/// `AnyWorkspaceEntry`: a registered workspace. The system workspace has no public view.
struct AnyWorkspaceEntry {
  let publicWorkspace: PresenceStatesImpl?
  let `internal`: any PresenceStatesInternal
}

/// `PresenceStatesInternal`: what the datastore manager calls on every workspace. `remoteDatastore`
/// is the workspace's part of an inbound `data` object, still as received.
protocol PresenceStatesInternal: AnyObject {
  func ensureContent(_ content: WorkspaceSchema, controls: BroadcastControlSettings?) throws
    -> PresenceStatesImpl

  func processUpdate(
    received: Double, timeModifier: Double, remoteDatastore: JSONValue,
    senderConnectionId: ClientConnectionId
  ) throws -> [PostUpdateAction]
}

/// Contract for `PresenceDatastoreManager` as required by States Workspaces (`PresenceRuntime`).
protocol PresenceRuntime: AnyObject {
  var presence: any Presence { get }
  var attendeeId: AttendeeId { get }
  var clock: any PresenceClock { get }

  /// `states` maps manager key to the manager's whole current value.
  func localUpdate(
    _ states: JSObject<ValueDirectoryOrState>, options: RuntimeLocalUpdateOptions
  ) throws
}

/// Merges a value directory. A leaf wins only if there is no base or its revision is greater; the
/// winner is cloned with `timestamp + timeDelta`. A directory update always recurses through every
/// update item, even when its own revision is equal or older, and never prunes absent keys.
func mergeValueDirectory(
  base: ValueDirectoryOrState?, update: ValueDirectoryOrState, timeDelta: Double
) -> ValueDirectoryOrState {
  switch update {
  case .state(let updateState):
    if let base, !(updateState.rev > base.rev) {
      return base
    }
    return .state(updateState.copy(addingTimeDelta: timeDelta))
  case .directory(let updateDirectory):
    let mergeBase: ValueDirectory
    if let base {
      if base.rev >= updateDirectory.rev {
        guard case .directory(let baseDirectory) = base else {
          // The base is a more recent leaf value: nothing to do.
          return base
        }
        // The base has a more advanced revision. Assume mis-ordering or a missed update and merge
        // the catch-up in.
        mergeBase = baseDirectory
      } else if case .directory(let baseDirectory) = base {
        mergeBase = ValueDirectory(rev: updateDirectory.rev, items: baseDirectory.items)
      } else {
        mergeBase = ValueDirectory(rev: updateDirectory.rev)
      }
    } else {
      mergeBase = ValueDirectory(rev: updateDirectory.rev)
    }
    for (key, value) in updateDirectory.items.entries {
      let baseElement = mergeBase.items[key]
      mergeBase.items[key] = mergeValueDirectory(base: baseElement, update: value, timeDelta: timeDelta)
    }
    return .directory(mergeBase)
  }
}

/// Updates remote state into the local, untracked datastore. Entries with an `ignoreUnmonitored`
/// property (even `false`) are not stored, though the value key is created.
func mergeUntrackedDatastore(
  key: JSString, remoteAllKnownState: JSONValue, datastore: ValueElementMap,
  timeModifier: Double
) throws {
  let localAllKnownState = datastore.record(for: key)
  for (attendeeId, valueJSON) in try remoteAllKnownState.asObject().entries {
    let value = try ValueDirectoryOrState(json: valueJSON)
    if case .state(let state) = value, state.ignoreUnmonitored != nil {
      continue
    }
    localAllKnownState.values[attendeeId] = mergeValueDirectory(
      base: localAllKnownState.values[attendeeId], update: value, timeDelta: timeModifier)
  }
}

/// The default allowable update latency for a states workspace in milliseconds.
private let defaultAllowableUpdateLatencyMs: Double = 60

/// Ports `PresenceStatesImpl`: a workspace of value managers. `states` and `notifications` are the
/// same object (TS views of one set of nodes), reached through the typed accessors below.
public final class PresenceStatesImpl: StateDatastore, PresenceStatesInternal {
  private let runtime: any PresenceRuntime
  private let datastore: ValueElementMap
  private var nodes = JSObject<any ValueManager>()
  public let controls: RequiredBroadcastControl

  init(
    runtime: any PresenceRuntime,
    datastore: ValueElementMap,
    initialContent: JSObject<any ManagerFactory>,
    controlsSettings: BroadcastControlSettings?
  ) throws {
    self.runtime = runtime
    self.datastore = datastore
    controls = RequiredBroadcastControl(
      defaultAllowableUpdateLatencyMs: defaultAllowableUpdateLatencyMs)
    if let latency = controlsSettings?.allowableUpdateLatencyMs {
      controls.setAllowableUpdateLatencyMs(latency)
    }

    // Prepare initial map content from initial state.
    let attendeeId = runtime.attendeeId
    var anyInitialValues = false
    var newValues = JSObject<ValueDirectoryOrState>()
    var cumulativeAllowableUpdateLatencyMs: Double?
    for (key, nodeFactory) in initialContent.entries {
      let instantiation = nodeFactory.instantiate(key: key, datastore: self)
      nodes[key] = instantiation.manager
      if let initialData = instantiation.initialData {
        datastore.record(for: key).values[attendeeId] = initialData.value
        newValues[key] = initialData.value
        if let latency = initialData.allowableUpdateLatencyMs {
          cumulativeAllowableUpdateLatencyMs = cumulativeAllowableUpdateLatencyMs.map { min($0, latency) } ?? latency
        }
        anyInitialValues = true
      }
    }

    if anyInitialValues {
      try runtime.localUpdate(
        newValues,
        options: RuntimeLocalUpdateOptions(
          allowableUpdateLatencyMs: cumulativeAllowableUpdateLatencyMs
            ?? controls.allowableUpdateLatencyMs))
    }
  }

  // MARK: Public views

  /// The `states` view: a registered manager by key.
  public func manager(_ key: JSString) -> (any ValueManager)? {
    nodes[key]
  }

  /// A registered `latest` manager, or a `TypeError`-style failure.
  public func latest(_ key: JSString) throws -> LatestValueManagerImpl {
    guard let manager = nodes[key] as? LatestValueManagerImpl else {
      throw PresenceError.failed("State \"\(key)\" is not a latest manager")
    }
    return manager
  }

  public func latestMap(_ key: JSString) throws -> LatestMapValueManagerImpl {
    guard let manager = nodes[key] as? LatestMapValueManagerImpl else {
      throw PresenceError.failed("State \"\(key)\" is not a latestMap manager")
    }
    return manager
  }

  public func notifications(_ key: JSString) throws -> NotificationsManagerImpl {
    guard let manager = nodes[key] as? NotificationsManagerImpl else {
      throw PresenceError.failed("State \"\(key)\" is not a notifications manager")
    }
    return manager
  }

  // MARK: StateDatastore

  public var presence: any Presence {
    runtime.presence
  }

  public var clock: any PresenceClock {
    runtime.clock
  }

  public func knownValues(_ key: JSString) -> (selfAttendeeId: AttendeeId, states: ClientRecord) {
    (runtime.attendeeId, datastore.record(for: key))
  }

  public func localUpdate(
    _ key: JSString, value: ValueDirectoryOrState, options: LocalStateUpdateOptions
  ) throws {
    var states = JSObject<ValueDirectoryOrState>()
    states[key] = value
    try runtime.localUpdate(
      states,
      options: RuntimeLocalUpdateOptions(
        allowableUpdateLatencyMs: options.allowableUpdateLatencyMs ?? controls.allowableUpdateLatencyMs,
        targetClientId: options.targetClientId))
  }

  public func update(_ key: JSString, clientId: AttendeeId, value: ValueDirectoryOrState) {
    let allKnownState = datastore.record(for: key)
    allKnownState.values[clientId] = mergeValueDirectory(
      base: allKnownState.values[clientId], update: value, timeDelta: 0)
  }

  // MARK: Registration

  /// Registers a new manager. Preexisting remote state for the key is kept but not replayed to the
  /// manager as events. Asserts the key is absent (0xa3c).
  func add(key: JSString, nodeFactory: any ManagerFactory) throws {
    try assertPresence(nodes[key] == nil, "0xa3c")
    let nodeData = nodeFactory.instantiate(key: key, datastore: self)
    nodes[key] = nodeData.manager
    if let initialData = nodeData.initialData {
      datastore.record(for: key).values[runtime.attendeeId] = initialData.value
      var values = JSObject<ValueDirectoryOrState>()
      values[key] = initialData.value
      try runtime.localUpdate(
        values,
        options: RuntimeLocalUpdateOptions(
          allowableUpdateLatencyMs: initialData.allowableUpdateLatencyMs
            ?? controls.allowableUpdateLatencyMs))
    }
  }

  func ensureContent(_ content: WorkspaceSchema, controls: BroadcastControlSettings?) throws
    -> PresenceStatesImpl
  {
    if let latency = controls?.allowableUpdateLatencyMs {
      self.controls.setAllowableUpdateLatencyMs(latency)
    }
    for (key, nodeFactory) in content.ordered.entries {
      if let existing = nodes[key] {
        if !nodeFactory.isInstance(existing) {
          throw PresenceError.failed("State \"\(key)\" previously created by different State object.")
        }
      } else {
        try add(key: key, nodeFactory: nodeFactory)
      }
    }
    return self
  }

  func processUpdate(
    received: Double, timeModifier: Double, remoteDatastore: JSONValue,
    senderConnectionId: ClientConnectionId
  ) throws -> [PostUpdateAction] {
    var postUpdateActions: [PostUpdateAction] = []
    for (key, remoteAllKnownState) in try remoteDatastore.asObject().entries {
      if let node = nodes[key] {
        for (attendeeId, valueJSON) in try remoteAllKnownState.asObject().entries {
          let client = try runtime.presence.attendees.getAttendee(attendeeId)
          let value = try ValueDirectoryOrState(json: valueJSON)
          postUpdateActions.append(
            contentsOf: try node.update(attendee: client, received: received, value: value))
        }
      } else {
        // Assume all broadcast state is meant to be kept even if not currently registered.
        try mergeUntrackedDatastore(
          key: key, remoteAllKnownState: remoteAllKnownState, datastore: datastore,
          timeModifier: timeModifier)
      }
    }
    return postUpdateActions
  }
}

/// Ports `createPresenceStates`.
func createPresenceStates(
  runtime: any PresenceRuntime,
  datastore: ValueElementMap,
  initialContent: WorkspaceSchema,
  controls: BroadcastControlSettings?
) throws -> AnyWorkspaceEntry {
  let workspace = try PresenceStatesImpl(
    runtime: runtime, datastore: datastore, initialContent: initialContent.ordered,
    controlsSettings: controls)
  return AnyWorkspaceEntry(publicWorkspace: workspace, internal: workspace)
}
