import FluidJS

/// Ports presence-runtime/src/runtime/protocol.ts. specs/presence.md §3 lists every message.

/// `Pres:DatastoreUpdate`.
public let datastoreUpdateMessageType: JSString = "Pres:DatastoreUpdate"

/// `Pres:ClientJoin`.
public let joinMessageType: JSString = "Pres:ClientJoin"

/// `Pres:Ack`.
public let acknowledgementMessageType: JSString = "Pres:Ack"

/// The data-store key of the system workspace.
let systemWorkspaceAddress: JSString = "system:presence"

/// `ConnectionValueState`: one `clientToSessionId` entry, `{rev, timestamp, value: attendeeId}`.
struct ConnectionValueState {
  var rev: Double
  var timestamp: Double?
  var value: AttendeeId

  var json: JSONValue {
    var object = JSObject<JSONValue>()
    object["rev"] = .number(rev)
    object["timestamp"] = timestamp.map { .number($0) } ?? .null
    object["value"] = .string(value)
    return .object(object)
  }

  init(rev: Double, timestamp: Double?, value: AttendeeId) {
    self.rev = rev
    self.timestamp = timestamp
    self.value = value
  }

  init(json: JSONValue) throws {
    let state = try ValueState(json: json)
    guard case .some(.string(let attendeeId)) = state.value else {
      throw JSONDecodingError("expected string attendee ID")
    }
    rev = state.rev
    timestamp = state.timestamp
    value = attendeeId
  }
}

/// `SystemWorkspaceDatastore`: shared between the system workspace (which updates it) and the
/// datastore manager (which broadcasts it).
final class SystemWorkspaceDatastore {
  var clientToSessionId = JSObject<ConnectionValueState>()

  var json: JSONValue {
    var mappings = JSObject<JSONValue>()
    for (connectionId, state) in clientToSessionId.entries {
      mappings[connectionId] = state.json
    }
    var object = JSObject<JSONValue>()
    object["clientToSessionId"] = .object(mappings)
    return .object(object)
  }
}

/// `GeneralDatastoreMessageContent[workspace]`: manager key to attendee ID to value.
typealias WorkspaceMessageContent = JSObject<JSObject<ValueDirectoryOrState>>

/// `GeneralDatastoreMessageContent`: internal workspace address (`s:` or `n:` prefix) to its content.
typealias GeneralDatastoreMessageContent = JSObject<WorkspaceMessageContent>

/// Outbound presence messages (`OutboundPresenceMessage`). `json` is the wire form
/// `{type, content, targetClientId?}` in the producers' key order.
public enum OutboundPresenceMessage {
  /// `Pres:ClientJoin`: `sendTimestamp, avgLatency, data, updateProviders`.
  case clientJoin(
    sendTimestamp: Double, avgLatency: Double, data: JSONValue, updateProviders: [ClientConnectionId])

  /// `Pres:DatastoreUpdate`. The incremental producer emits `sendTimestamp, avgLatency, data`;
  /// the complete producer emits `sendTimestamp, avgLatency, isComplete, data` and then appends
  /// `joinResponseFor` when there are requests.
  case datastoreUpdate(
    sendTimestamp: Double, avgLatency: Double, isComplete: Bool, data: JSONValue,
    joinResponseFor: [ClientConnectionId]?)

  /// `Pres:Ack`: `type, content, targetClientId`.
  case acknowledgement(id: JSString, targetClientId: ClientConnectionId)

  public var targetClientId: ClientConnectionId? {
    if case .acknowledgement(_, let target) = self {
      return target
    }
    return nil
  }

  public var json: JSONValue {
    var message = JSObject<JSONValue>()
    var content = JSObject<JSONValue>()
    switch self {
    case .clientJoin(let sendTimestamp, let avgLatency, let data, let updateProviders):
      message["type"] = .string(joinMessageType)
      content["sendTimestamp"] = .number(sendTimestamp)
      content["avgLatency"] = .number(avgLatency)
      content["data"] = data
      content["updateProviders"] = .array(updateProviders.map { .string($0) })
    case .datastoreUpdate(let sendTimestamp, let avgLatency, let isComplete, let data, let joinResponseFor):
      message["type"] = .string(datastoreUpdateMessageType)
      content["sendTimestamp"] = .number(sendTimestamp)
      content["avgLatency"] = .number(avgLatency)
      if isComplete {
        content["isComplete"] = .bool(true)
      }
      content["data"] = data
      if let joinResponseFor {
        content["joinResponseFor"] = .array(joinResponseFor.map { .string($0) })
      }
    case .acknowledgement(let id, let targetClientId):
      message["type"] = .string(acknowledgementMessageType)
      content["id"] = .string(id)
      message["content"] = .object(content)
      message["targetClientId"] = .string(targetClientId)
      return .object(message)
    }
    message["content"] = .object(content)
    return .object(message)
  }
}

/// Decoded content of an inbound `Pres:ClientJoin`.
struct ClientJoinContent {
  var updateProviders: [ClientConnectionId]
  var sendTimestamp: Double
  var avgLatency: Double
  var data: JSObject<JSONValue>
}

/// Decoded content of an inbound `Pres:DatastoreUpdate`.
struct DatastoreUpdateContent {
  var sendTimestamp: Double
  var avgLatency: Double
  var acknowledgementId: JSString?
  var joinResponseFor: [ClientConnectionId]?
  var data: JSObject<JSONValue>
}

/// An inbound presence message. `Pres:Ack` is a known type with no content handling: see
/// `PresenceDatastoreManagerImpl.processSignal` and specs/presence.md "Ack implementation hole".
enum InboundPresenceMessage {
  case join(ClientJoinContent)
  case update(DatastoreUpdateContent)
  case acknowledgement

  /// `nil` for a type presence does not know (`isPresenceMessage` is false).
  init?(_ message: InboundExtensionMessage) throws {
    switch message.type {
    case joinMessageType:
      let content = try Self.content(of: message)
      self = .join(
        ClientJoinContent(
          updateProviders: try requiredMember(content, "updateProviders").asArray().map {
            try $0.asString()
          },
          sendTimestamp: try Self.jsNumber(requiredMember(content, "sendTimestamp")),
          avgLatency: try Self.jsNumber(requiredMember(content, "avgLatency")),
          data: try requiredMember(content, "data").asObject()))
    case datastoreUpdateMessageType:
      let content = try Self.content(of: message)
      var acknowledgementId: JSString?
      if let value = content["acknowledgementId"] {
        acknowledgementId = try value.asString()
      }
      var joinResponseFor: [ClientConnectionId]?
      if let value = content["joinResponseFor"] {
        joinResponseFor = try value.asArray().map { try $0.asString() }
      }
      self = .update(
        DatastoreUpdateContent(
          sendTimestamp: try Self.jsNumber(requiredMember(content, "sendTimestamp")),
          avgLatency: try Self.jsNumber(requiredMember(content, "avgLatency")),
          acknowledgementId: acknowledgementId,
          joinResponseFor: joinResponseFor,
          data: try requiredMember(content, "data").asObject()))
    case acknowledgementMessageType:
      self = .acknowledgement
    default:
      return nil
    }
  }

  private static func content(of message: InboundExtensionMessage) throws -> JSObject<JSONValue> {
    guard let content = message.content else {
      throw JSONDecodingError("missing signal content")
    }
    return try content.asObject()
  }

  /// A numeric field that crossed JSON. `null` is a NaN that was serialized (JSON has no NaN) and
  /// JS arithmetic treats it as 0.
  private static func jsNumber(_ value: JSONValue) throws -> Double {
    if case .null = value {
      return 0
    }
    return try value.asNumber()
  }
}
