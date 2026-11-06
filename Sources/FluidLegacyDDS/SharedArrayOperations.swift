import FluidJS
import FluidSharedObjectBase

/// The numeric `type` of a SharedArray op. Port of `packages/dds/legacy-dds/src/array/sharedArrayOperations.ts`
/// OperationType.
public enum OperationType: Int, Sendable {
  case insertEntry = 0
  case deleteEntry = 1
  case moveEntry = 2
  case toggle = 3
  case toggleMove = 4
}

/// Port of `sharedArrayOperations.ts` IInsertOperation. `insertAfterEntryId` is absent to insert at the start.
public struct IInsertOperation: Equatable, Sendable {
  public let entryId: JSString
  public let value: FluidValue
  public let insertAfterEntryId: JSString?

  public init(entryId: JSString, value: FluidValue, insertAfterEntryId: JSString?) {
    self.entryId = entryId
    self.value = value
    self.insertAfterEntryId = insertAfterEntryId
  }
}

/// Port of `sharedArrayOperations.ts` IDeleteOperation.
public struct IDeleteOperation: Equatable, Sendable {
  public let entryId: JSString

  public init(entryId: JSString) {
    self.entryId = entryId
  }
}

/// Port of `sharedArrayOperations.ts` IMoveOperation. `entryId` is the old position, `changedToEntryId` the new one.
public struct IMoveOperation: Equatable, Sendable {
  public let entryId: JSString
  public let insertAfterEntryId: JSString?
  public let changedToEntryId: JSString

  public init(entryId: JSString, insertAfterEntryId: JSString?, changedToEntryId: JSString) {
    self.entryId = entryId
    self.insertAfterEntryId = insertAfterEntryId
    self.changedToEntryId = changedToEntryId
  }
}

/// Port of `sharedArrayOperations.ts` IToggleOperation.
public struct IToggleOperation: Equatable, Sendable {
  public let entryId: JSString
  public let isDeleted: Bool

  public init(entryId: JSString, isDeleted: Bool) {
    self.entryId = entryId
    self.isDeleted = isDeleted
  }
}

/// Port of `sharedArrayOperations.ts` IToggleMoveOperation.
public struct IToggleMoveOperation: Equatable, Sendable {
  public let entryId: JSString
  public let changedToEntryId: JSString

  public init(entryId: JSString, changedToEntryId: JSString) {
    self.entryId = entryId
    self.changedToEntryId = changedToEntryId
  }
}

/// Port of `sharedArrayOperations.ts` ISharedArrayOperation: the union of the five op shapes.
public enum ISharedArrayOperation: Equatable, Sendable {
  case insert(IInsertOperation)
  case delete(IDeleteOperation)
  case move(IMoveOperation)
  case toggle(IToggleOperation)
  case toggleMove(IToggleMoveOperation)

  public var type: OperationType {
    switch self {
    case .insert: .insertEntry
    case .delete: .deleteEntry
    case .move: .moveEntry
    case .toggle: .toggle
    case .toggleMove: .toggleMove
    }
  }

  /// The op as it travels on the wire. Fields follow the producer's order in `sharedArray.ts`, and an absent
  /// `insertAfterEntryId` is omitted, as `JSON.stringify` omits `undefined`. Handles in a value are encoded.
  public func json(_ serializer: FluidSerializer) -> JSONValue {
    var object = JSObject<JSONValue>()
    object["type"] = .number(Double(type.rawValue))
    switch self {
    case .insert(let op):
      object["entryId"] = .string(op.entryId)
      object["value"] = serializer.encode(op.value)
      object["insertAfterEntryId"] = op.insertAfterEntryId.map(JSONValue.string)
    case .delete(let op):
      object["entryId"] = .string(op.entryId)
    case .move(let op):
      object["entryId"] = .string(op.entryId)
      object["insertAfterEntryId"] = op.insertAfterEntryId.map(JSONValue.string)
      object["changedToEntryId"] = .string(op.changedToEntryId)
    case .toggle(let op):
      object["entryId"] = .string(op.entryId)
      object["isDeleted"] = .bool(op.isDeleted)
    case .toggleMove(let op):
      object["entryId"] = .string(op.entryId)
      object["changedToEntryId"] = .string(op.changedToEntryId)
    }
    return .object(object)
  }

  /// Reads an op from its wire JSON. An unknown `type` throws `Unknown operation`, as `processMessage` does.
  public init(json: JSONValue, serializer: FluidSerializer) throws {
    let object = try json.asObject()
    guard
      case .number(let number)? = object["type"],
      let int = Int(exactly: number),
      let type = OperationType(rawValue: int)
    else {
      throw SharedObjectError("Unknown operation")
    }
    let entryId = try json.member("entryId").asString()
    switch type {
    case .insertEntry:
      guard let value = object["value"] else {
        throw SharedObjectError("Invalid operation: an insert has no value")
      }
      self = .insert(
        IInsertOperation(
          entryId: entryId, value: try serializer.decode(value),
          insertAfterEntryId: try Self.optionalString(object["insertAfterEntryId"])))
    case .deleteEntry:
      self = .delete(IDeleteOperation(entryId: entryId))
    case .moveEntry:
      self = .move(
        IMoveOperation(
          entryId: entryId, insertAfterEntryId: try Self.optionalString(object["insertAfterEntryId"]),
          changedToEntryId: try json.member("changedToEntryId").asString()))
    case .toggle:
      self = .toggle(
        IToggleOperation(entryId: entryId, isDeleted: try Self.bool(json.member("isDeleted"))))
    case .toggleMove:
      self = .toggleMove(
        IToggleMoveOperation(
          entryId: entryId, changedToEntryId: try json.member("changedToEntryId").asString()))
    }
  }

  private static func optionalString(_ value: JSONValue?) throws -> JSString? {
    try value.map { try $0.asString() }
  }

  private static func bool(_ value: JSONValue) throws -> Bool {
    guard case .bool(let bool) = value else {
      throw JSONDecodingError("expected boolean, got \(value)")
    }
    return bool
  }
}
