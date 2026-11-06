import FluidJS

public struct FluidHandle: Equatable, Sendable {
  public let absolutePath: JSString
  public let payloadPending: Bool
  public init(absolutePath: JSString, payloadPending: Bool = false) {
    self.absolutePath = absolutePath
    self.payloadPending = payloadPending
  }
}

/// Values at the DDS boundary include handles and undefined, neither of which is JSON.
public indirect enum FluidValue: Equatable, Sendable {
  case undefined
  case json(JSONValue)
  case handle(FluidHandle)
  case array([FluidValue])
  case object(JSObject<FluidValue>)
}

public struct FluidSerializer {
  public let contextPath: JSString
  public init(contextPath: JSString = "") { self.contextPath = contextPath }

  public func encode(_ value: FluidValue, bind: (FluidHandle) -> Void = { _ in }) -> JSONValue {
    switch value {
    case .undefined: return .null  // Array slots; object members are omitted below.
    case .json(let value): return value
    case .handle(let handle):
      bind(handle)
      var object = JSObject<JSONValue>()
      object["type"] = .string("__fluid_handle__")
      object["url"] = .string(handle.absolutePath)
      if handle.payloadPending { object["payloadPending"] = .bool(true) }
      return .object(object)
    case .array(let values): return .array(values.map { encode($0, bind: bind) })
    case .object(let values):
      var object = JSObject<JSONValue>()
      for (key, value) in values.entries where value != .undefined {
        object[key] = encode(value, bind: bind)
      }
      return .object(object)
    }
  }

  public func decode(_ value: JSONValue) throws -> FluidValue {
    switch value {
    case .object(let values):
      if values["type"] == .string("__fluid_handle__") {
        let url = try value.member("url").asString()
        let path =
          url.description.hasPrefix("/")
          ? url : JSString(contextPath.description + "/" + url.description)
        return .handle(
          FluidHandle(absolutePath: path, payloadPending: values["payloadPending"] == .bool(true)))
      }
      var object = JSObject<FluidValue>()
      for (key, value) in values.entries { object[key] = try decode(value) }
      return .object(object)
    case .array(let values): return .array(try values.map(decode))
    default: return .json(value)
    }
  }
  public func stringify(_ value: FluidValue, bind: (FluidHandle) -> Void = { _ in }) -> String {
    JSON.stringify(encode(value, bind: bind))
  }
  public func parse(_ text: String) throws -> FluidValue { try decode(JSON.parse(text)) }
}
