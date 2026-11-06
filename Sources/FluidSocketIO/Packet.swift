import FluidJS

public enum SocketIOError: Error, Sendable {
    case protocolError(String)
    case closed(String)
}

/// Socket.IO protocol 5, default namespace, JSON-only subset used by routerlicious.
public struct SocketPacket: Equatable, Sendable {
    public enum Kind: Int, Sendable { case connect = 0, disconnect, event, ack, connectError }
    public var kind: Kind
    public var id: Int?
    public var data: JSONValue?

    public init(_ kind: Kind, id: Int? = nil, data: JSONValue? = nil) {
        self.kind = kind
        self.id = id
        self.data = data
    }

    public func encode() throws -> String {
        try validate()
        return String(kind.rawValue) + (id.map(String.init) ?? "") + (data.map(JSON.stringify) ?? "")
    }

    public static func decode(_ text: String) throws -> SocketPacket {
        guard let first = text.first, first.isASCII, let number = first.wholeNumberValue,
              let kind = Kind(rawValue: number) else {
            throw SocketIOError.protocolError("unsupported Socket.IO packet")
        }
        var rest = text.dropFirst()
        if rest.hasPrefix("/") {
            guard rest.hasPrefix("/,") else { throw SocketIOError.protocolError("non-default namespace") }
            rest = rest.dropFirst(2)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let id = digits.isEmpty ? nil : Int(digits)
        if !digits.isEmpty && id == nil { throw SocketIOError.protocolError("ack id overflow") }
        rest = rest.dropFirst(digits.count)
        let packet = SocketPacket(kind, id: id, data: rest.isEmpty ? nil : try JSON.parse(String(rest)))
        try packet.validate()
        return packet
    }

    private func validate() throws {
        if let id, id < 0 { throw SocketIOError.protocolError("negative ack id") }
        switch kind {
        case .connect:
            if let data { _ = try data.asObject() }
        case .disconnect:
            guard data == nil, id == nil else { throw SocketIOError.protocolError("disconnect payload") }
        case .event:
            let values = try data?.asArray() ?? []
            guard let name = values.first, case .string = name else { throw SocketIOError.protocolError("event name") }
        case .ack:
            guard id != nil, let data else { throw SocketIOError.protocolError("ack payload") }
            _ = try data.asArray()
        case .connectError:
            guard let data else { throw SocketIOError.protocolError("connect error payload") }
            switch data { case .string, .object: break
            default: throw SocketIOError.protocolError("connect error payload") }
        }
    }
}

public enum EnginePacket: Equatable, Sendable {
    case open(JSONValue), close, ping(String), pong(String), message(SocketPacket), noop

    public static func decode(_ text: String) throws -> EnginePacket {
        let body = String(text.dropFirst())
        switch text.first {
        case "0": return .open(try JSON.parse(body))
        case "1": return .close
        case "2": return .ping(body)
        case "3": return .pong(body)
        case "4": return .message(try SocketPacket.decode(body))
        case "6": return .noop
        default: throw SocketIOError.protocolError("unsupported Engine.IO packet")
        }
    }

    public func encode() throws -> String {
        switch self {
        case .open(let data): return "0" + JSON.stringify(data)
        case .close: return "1"
        case .ping(let data): return "2" + data
        case .pong(let data): return "3" + data
        case .message(let packet): return "4" + (try packet.encode())
        case .noop: return "6"
        }
    }
}
