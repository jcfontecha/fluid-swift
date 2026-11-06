import FluidJS

/// Ports driver-definitions/src/urlResolver.ts: IResolvedUrl, preserving received extensions.
public struct IResolvedUrl: DriverJSONValue {
    public let json: JSONValue
    public let id: JSString
    public let url: JSString
    public let tokens: JSObject<JSString>
    public let endpoints: JSObject<JSString>

    public init(json: JSONValue) throws {
        guard try json.member("type").asString() == "fluid" else {
            throw JSONDecodingError("invalid resolved URL type")
        }
        id = try json.member("id").asString()
        url = try json.member("url").asString()
        tokens = try decodeMap(json.member("tokens")) { try $0.asString() }
        endpoints = try decodeMap(json.member("endpoints")) { try $0.asString() }
        self.json = json
    }
}
