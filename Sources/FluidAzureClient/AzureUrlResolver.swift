import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import Foundation

/// Ports azure-client/src/AzureUrlResolver.ts `AzureUrlResolver`: resolves Azure Fluid Relay
/// requests, whose URL is the service endpoint with `storage`, `tenantId` and (except for a
/// create-new request) `containerId` query parameters.
public struct AzureUrlResolver: IUrlResolver {
    public init() {}

    /// AzureUrlResolver.ts `resolve`. The tenant and container IDs go into the URLs decoded and
    /// unescaped, as TS writes them.
    public func resolve(_ request: IRequest) async throws -> IResolvedUrl? {
        let decoded = try decodeAzureUrl(request.url)
        // A create-new request has the `createNew` header set to true and no container ID.
        if request.headers?["createNew"] == .bool(true) {
            // id is mandatory but the driver ignores it for new container requests.
            return try resolvedUrl(
                deltaStorageUrl: "\(decoded.ordererUrl)/deltas/\(decoded.tenantId)/new",
                ordererUrl: decoded.ordererUrl,
                storageUrl: "\(decoded.storageUrl)/repos/\(decoded.tenantId)",
                id: "",
                url: "\(decoded.ordererUrl)/\(decoded.tenantId)/new")
        }
        guard let containerId = decoded.containerId else {
            throw JSONDecodingError("Azure URL did not contain containerId")
        }
        return try resolvedUrl(
            deltaStorageUrl: "\(decoded.ordererUrl)/deltas/\(decoded.tenantId)/\(containerId)",
            ordererUrl: decoded.ordererUrl,
            storageUrl: "\(decoded.storageUrl)/repos/\(decoded.tenantId)",
            id: containerId,
            url: "\(decoded.ordererUrl)/\(decoded.tenantId)/\(containerId)")
    }

    /// AzureUrlResolver.ts `getAbsoluteUrl`. `IResolvedUrl` only decodes `type: "fluid"`, so
    /// TS's "Invalid Resolved Url" check always passes here.
    public func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String {
        "\(resolvedUrl.url)/\(relativeUrl)"
    }

    /// The resolved URL in TS property order. `tokens` is empty: the token provider issues every
    /// token.
    private func resolvedUrl(
        deltaStorageUrl: String,
        ordererUrl: String,
        storageUrl: String,
        id: String,
        url: String
    ) throws -> IResolvedUrl {
        var endpoints = JSObject<JSONValue>()
        endpoints["deltaStorageUrl"] = .string(JSString(deltaStorageUrl))
        endpoints["ordererUrl"] = .string(JSString(ordererUrl))
        endpoints["storageUrl"] = .string(JSString(storageUrl))
        var result = JSObject<JSONValue>()
        result["endpoints"] = .object(endpoints)
        result["id"] = .string(JSString(id))
        result["tokens"] = .object(JSObject())
        result["type"] = .string("fluid")
        result["url"] = .string(JSString(url))
        return try IResolvedUrl(json: .object(result))
    }
}

/// AzureUrlResolver.ts `decodeAzureUrl`: the URL's origin is the orderer. Each parameter is
/// form-decoded by `URLSearchParams`, then `decodeURIComponent` undoes the encoding the client
/// applied before appending it.
private func decodeAzureUrl(_ urlString: String) throws -> (
    ordererUrl: String, storageUrl: String, tenantId: String, containerId: String?
) {
    let url = try WebURL(urlString)
    guard let storageUrl = url.searchParams.first(where: { $0.name == "storage" })?.value else {
        throw JSONDecodingError("Azure URL did not contain a storage URL")
    }
    guard let tenantId = url.searchParams.first(where: { $0.name == "tenantId" })?.value else {
        throw JSONDecodingError("Azure URL did not contain a tenant ID")
    }
    let containerId = try url.searchParams.first { $0.name == "containerId" }.map { try decodeURIComponent($0.value) }
    return (url.origin, try decodeURIComponent(storageUrl), try decodeURIComponent(tenantId), containerId)
}

/// AzureUrlResolver.ts `createAzureCreateNewRequest`: the request `FluidContainer.attach` passes
/// to create a container on the service.
func createAzureCreateNewRequest(endpointUrl: String, tenantId: String) throws -> IRequest {
    var url = try WebURL(endpointUrl)
    url.searchParams.append((name: "storage", value: encodeURIComponent(endpointUrl)))
    url.searchParams.append((name: "tenantId", value: encodeURIComponent(tenantId)))
    var headers = JSObject<JSONValue>()
    headers["createNew"] = .bool(true)
    return IRequest(url: url.href, headers: headers)
}

/// The request URL `AzureClient` loads a container with: `new URL(endpoint)`, then
/// `url.searchParams.append` of `storage`, `tenantId` and `containerId`, each already
/// `encodeURIComponent`-encoded, then `url.href`.
func createAzureRequestUrl(endpoint: String, tenantId: String, containerId: String) throws -> String {
    var url = try WebURL(endpoint)
    url.searchParams.append((name: "storage", value: encodeURIComponent(endpoint)))
    url.searchParams.append((name: "tenantId", value: encodeURIComponent(tenantId)))
    url.searchParams.append((name: "containerId", value: encodeURIComponent(containerId)))
    return url.href
}

/// The parts of a WHATWG `URL` the Azure client reads and writes: `origin`, `searchParams` and
/// `href`. Appending to `searchParams` re-serializes the whole query (URL standard "update
/// steps"), so an endpoint's own query comes back form-encoded, as in TS.
struct WebURL {
    let origin: String
    let path: String
    let fragment: String?
    var searchParams: [(name: String, value: String)]

    /// `new URL(string)`: an unparsable URL is a TypeError.
    init(_ string: String) throws {
        guard let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            throw JSONDecodingError("TypeError: Invalid URL")
        }
        // URL standard: a scheme's default port is not serialized.
        let defaultPort = ["http": 80, "https": 443, "ws": 80, "wss": 443][scheme]
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        origin = "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
        // A special URL's empty path serializes as "/".
        path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        fragment = components.percentEncodedFragment
        searchParams = parseFormUrlEncoded(components.percentEncodedQuery ?? "")
    }

    var href: String {
        let query = searchParams.isEmpty ? "" : "?" + serializeFormUrlEncoded(searchParams)
        return origin + path + query + (fragment.map { "#" + $0 } ?? "")
    }
}

/// URL standard application/x-www-form-urlencoded parser: `+` is a space and an invalid percent
/// sequence stays as it is.
private func parseFormUrlEncoded(_ query: String) -> [(name: String, value: String)] {
    query.split(separator: "&", omittingEmptySubsequences: true).map { sequence in
        let split = sequence.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = percentDecodeForm(String(split[0]))
        let value = percentDecodeForm(split.count > 1 ? String(split[1]) : "")
        return (name, value)
    }
}

private func percentDecodeForm(_ text: String) -> String {
    let input = Array(text.utf8)
    var bytes: [UInt8] = []
    var index = 0
    while index < input.count {
        if input[index] == UInt8(ascii: "+") {
            bytes.append(UInt8(ascii: " "))
            index += 1
        } else if input[index] == UInt8(ascii: "%"), index + 2 < input.count,
            let byte = UInt8(String(decoding: input[index + 1...index + 2], as: UTF8.self), radix: 16)
        {
            bytes.append(byte)
            index += 3
        } else {
            bytes.append(input[index])
            index += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// URL standard application/x-www-form-urlencoded serializer: `*-._`, digits and ASCII letters
/// stay, a space becomes `+`, every other UTF-8 byte is `%XX` in uppercase hex.
private func serializeFormUrlEncoded(_ pairs: [(name: String, value: String)]) -> String {
    pairs.map { formEncode($0.name) + "=" + formEncode($0.value) }.joined(separator: "&")
}

private func formEncode(_ text: String) -> String {
    var output = ""
    for byte in text.utf8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "*"), UInt8(ascii: "-"),
            UInt8(ascii: "."), UInt8(ascii: "_"):
            output.unicodeScalars.append(Unicode.Scalar(byte))
        case UInt8(ascii: " "):
            output += "+"
        default:
            output += String(format: "%%%02X", byte)
        }
    }
    return output
}

/// `decodeURIComponent`: a malformed escape is a URIError.
private func decodeURIComponent(_ value: String) throws -> String {
    guard let decoded = value.removingPercentEncoding else {
        throw JSONDecodingError("URIError: URI malformed")
    }
    return decoded
}
