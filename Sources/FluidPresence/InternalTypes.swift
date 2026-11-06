import FluidJS

/// Ports presence-definitions/src/exposedInternalTypes.ts (`InternalTypes`) and the validatable
/// variants of presence-definitions/src/validatableTypes.ts. TS objects that are shared and
/// mutated in place are reference types here (`ValueState`, `ValueDirectory`, and the two record
/// types below); only reference types can reproduce the aliasing the oracle shows.

func requiredMember(_ object: JSObject<JSONValue>, _ key: JSString) throws -> JSONValue {
  guard let value = object[key] else {
    throw JSONDecodingError("missing member \"\(key)\"")
  }
  return value
}

/// The `validatedValue` property of a state. A validating getter caches its result here, but the
/// property is an ordinary object property in TS: it is serialized by any send that does not strip
/// it (partial updates of local values, for one), and a receiver that finds it already present
/// returns it without running its own validator. `value` and `validatedValue` keep their JS
/// insertion order: `precedesValue` is set when `value` was (re-)added after `validatedValue`.
struct ValidationSlot {
  let value: JSONValue?
  var precedesValue: Bool
}

/// `ValueRequiredState`, `ValueOptionalState` and the notification state: `{rev, timestamp, value?,
/// ignoreUnmonitored?}`. An absent `value` is a map tombstone, which is not `value: null`.
public final class ValueState {
  public var rev: Double
  /// `nil` is a JS `null` timestamp. It appears when a peer's NaN (see `Pres:Ack`) crossed JSON.
  public var timestamp: Double?
  public var value: JSONValue? {
    didSet {
      // `delete item.value` followed by `item.value = x` re-adds the property after validatedValue.
      if oldValue == nil, value != nil, validated != nil {
        validated?.precedesValue = true
      }
    }
  }
  /// Whether the `ignoreUnmonitored` property exists (`"ignoreUnmonitored" in value`) and what it holds.
  public var ignoreUnmonitored: JSONValue?
  var validated: ValidationSlot?

  public init(
    rev: Double,
    timestamp: Double?,
    value: JSONValue? = nil,
    ignoreUnmonitored: JSONValue? = nil
  ) {
    self.rev = rev
    self.timestamp = timestamp
    self.value = value
    self.ignoreUnmonitored = ignoreUnmonitored
  }

  /// `{ ...state }`.
  func copy() -> ValueState {
    let result = ValueState(
      rev: rev, timestamp: timestamp, value: value, ignoreUnmonitored: ignoreUnmonitored)
    result.validated = validated
    return result
  }

  /// `{ ...update, timestamp: update.timestamp + timeDelta }`. JS adds `null` as 0.
  func copy(addingTimeDelta timeDelta: Double) -> ValueState {
    let result = copy()
    result.timestamp = (timestamp ?? 0) + timeDelta
    return result
  }

  /// Wire form, properties in JS insertion order, including `validatedValue` when present.
  public var json: JSONValue {
    var object = JSObject<JSONValue>()
    object["rev"] = .number(rev)
    object["timestamp"] = timestamp.map { .number($0) } ?? .null
    if let validated, validated.precedesValue {
      object["validatedValue"] = validated.value
    }
    object["value"] = value
    object["ignoreUnmonitored"] = ignoreUnmonitored
    if let validated, !validated.precedesValue {
      object["validatedValue"] = validated.value
    }
    return .object(object)
  }

  init(json: JSONValue) throws {
    let object = try json.asObject()
    rev = try requiredMember(object, "rev").asNumber()
    switch object["timestamp"] {
    case .some(.null): timestamp = nil
    case .some(let number): timestamp = try number.asNumber()
    case .none: throw JSONDecodingError("missing member \"timestamp\"")
    }
    value = object["value"]
    ignoreUnmonitored = object["ignoreUnmonitored"]
    if let received = object["validatedValue"] {
      let keys = object.keys
      let valueIndex = keys.firstIndex(of: "value")
      let validatedIndex = keys.firstIndex(of: "validatedValue")
      var precedesValue = true
      if let valueIndex, let validatedIndex {
        precedesValue = validatedIndex < valueIndex
      }
      validated = ValidationSlot(value: received, precedesValue: precedesValue)
    }
  }
}

/// `ValueDirectory` / `MapValueState`: `{rev, items}`. No timestamp at directory level.
public final class ValueDirectory {
  public var rev: Double
  public var items: JSObject<ValueDirectoryOrState>

  public init(rev: Double, items: JSObject<ValueDirectoryOrState> = JSObject()) {
    self.rev = rev
    self.items = items
  }

  public var json: JSONValue {
    var itemObject = JSObject<JSONValue>()
    for (key, item) in items.entries {
      itemObject[key] = item.json
    }
    var object = JSObject<JSONValue>()
    object["rev"] = .number(rev)
    object["items"] = .object(itemObject)
    return .object(object)
  }

  init(json: JSONValue) throws {
    let object = try json.asObject()
    rev = try requiredMember(object, "rev").asNumber()
    var decoded = JSObject<ValueDirectoryOrState>()
    for (key, item) in try json.member("items").asObject().entries {
      decoded[key] = try ValueDirectoryOrState(json: item)
    }
    items = decoded
  }
}

/// `ValueDirectoryOrState`: a directory iff the object has an `items` property
/// (`"items" in value`).
public enum ValueDirectoryOrState {
  case state(ValueState)
  case directory(ValueDirectory)

  public var rev: Double {
    switch self {
    case .state(let state): return state.rev
    case .directory(let directory): return directory.rev
    }
  }

  public var json: JSONValue {
    switch self {
    case .state(let state): return state.json
    case .directory(let directory): return directory.json
    }
  }

  init(json: JSONValue) throws {
    if try json.asObject()["items"] != nil {
      self = .directory(try ValueDirectory(json: json))
    } else {
      self = .state(try ValueState(json: json))
    }
  }
}

/// `ClientRecord<...>`: attendee ID to that attendee's value. One per value manager.
public final class ClientRecord {
  public var values = JSObject<ValueDirectoryOrState>()

  public init() {}
}

/// `ValueElementMap`: value manager key to its client record. One per workspace; shared between
/// the datastore manager (which broadcasts it) and the workspace (which updates it).
public final class ValueElementMap {
  public var records = JSObject<ClientRecord>()

  public init() {}

  /// `getOrCreateRecord(datastore, key, () => ({}))`.
  func record(for key: JSString) -> ClientRecord {
    if let existing = records[key] {
      return existing
    }
    let created = ClientRecord()
    records[key] = created
    return created
  }
}

/// `PostUpdateAction`: an event emission deferred until every workspace has processed an update.
public typealias PostUpdateAction = () throws -> Void

/// `RuntimeLocalUpdateOptions`: `LocalStateUpdateOptions` with the latency resolved.
public struct RuntimeLocalUpdateOptions {
  public var allowableUpdateLatencyMs: Double
  public var targetClientId: ClientConnectionId?

  public init(allowableUpdateLatencyMs: Double, targetClientId: ClientConnectionId? = nil) {
    self.allowableUpdateLatencyMs = allowableUpdateLatencyMs
    self.targetClientId = targetClientId
  }
}

/// `LocalStateUpdateOptions`.
public struct LocalStateUpdateOptions {
  public var allowableUpdateLatencyMs: Double?
  public var targetClientId: ClientConnectionId?

  public init(allowableUpdateLatencyMs: Double?, targetClientId: ClientConnectionId? = nil) {
    self.allowableUpdateLatencyMs = allowableUpdateLatencyMs
    self.targetClientId = targetClientId
  }
}

/// `ValueManager` (presence-definitions exposedInternalTypes.ts): what a workspace calls on each
/// registered manager.
public protocol ValueManager: AnyObject {
  func update(
    attendee: any Attendee, received: Double, value: ValueDirectoryOrState
  ) throws -> [PostUpdateAction]
}

/// `StateDatastore` (presence-definitions workspace-states/stateDatastoreTypes.ts): the workspace
/// as seen by its value managers.
public protocol StateDatastore: AnyObject {
  var presence: any Presence { get }
  var clock: any PresenceClock { get }

  /// The record for `key`, which the caller must have registered.
  func knownValues(_ key: JSString) -> (selfAttendeeId: AttendeeId, states: ClientRecord)

  func localUpdate(
    _ key: JSString, value: ValueDirectoryOrState, options: LocalStateUpdateOptions
  ) throws

  func update(_ key: JSString, clientId: AttendeeId, value: ValueDirectoryOrState)
}

/// The result of a `ManagerFactory` instantiation: the manager and, for states, the initial local
/// value to install in the datastore and broadcast.
public struct ManagerInstantiation {
  public struct InitialData {
    public let value: ValueDirectoryOrState
    public let allowableUpdateLatencyMs: Double?

    public init(value: ValueDirectoryOrState, allowableUpdateLatencyMs: Double?) {
      self.value = value
      self.allowableUpdateLatencyMs = allowableUpdateLatencyMs
    }
  }

  public let initialData: InitialData?
  public let manager: any ValueManager

  public init(initialData: InitialData?, manager: any ValueManager) {
    self.initialData = initialData
    self.manager = manager
  }
}

/// `ManagerFactory` with its `instanceBase`: `isInstance` is `manager instanceof factory.instanceBase`.
public protocol ManagerFactory {
  func instantiate(key: JSString, datastore: any StateDatastore) -> ManagerInstantiation
  func isInstance(_ manager: any ValueManager) -> Bool
}

/// `StatesWorkspaceSchema` / `NotificationsWorkspaceSchema`: manager key to factory, in the
/// caller's order. (TS iterates the object with `Object.entries`; the target is a `JSObject`.)
public struct WorkspaceSchema {
  public var entries: [(key: JSString, factory: any ManagerFactory)]

  public init(_ entries: [(key: JSString, factory: any ManagerFactory)]) {
    self.entries = entries
  }

  /// `Object.entries(schema)` order: array-index keys first, a repeated key keeps the last factory.
  var ordered: JSObject<any ManagerFactory> {
    var object = JSObject<any ManagerFactory>()
    for entry in entries {
      object[entry.key] = entry.factory
    }
    return object
  }
}
