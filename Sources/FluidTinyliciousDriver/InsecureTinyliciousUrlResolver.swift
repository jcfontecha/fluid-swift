import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import Foundation

/// Ports tinylicious-driver/src/insecureTinyliciousUrlResolver.ts.
public struct InsecureTinyliciousUrlResolver: Sendable {
    public let endpoint: String
    public init(port: Int? = nil, endpoint: String = "http://localhost") throws {
        guard var url = URLComponents(string: endpoint), let scheme = url.scheme,
            let host = url.host
        else { throw JSONDecodingError("invalid Tinylicious endpoint") }
        if let port { url.port = port } else if url.port == nil { url.port = 7070 }
        let effectivePort = url.port
        let suffix =
            effectivePort.map {
                ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? "" : ":\($0)"
            } ?? ""
        self.endpoint = "\(scheme)://\(host)\(suffix)"
    }
    public func resolve(_ request: String, createNew: Bool = false) throws -> IResolvedUrl {
        let relative = request.replacingOccurrences(
            of: endpoint + "/", with: "", options: [], range: request.range(of: endpoint + "/"))
        let first = String(
            relative.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        let id = createNew ? (first.isEmpty ? "new" : first) : first
        let encoded = encodeURIComponent(id)
        var endpoints = JSObject<JSONValue>()
        endpoints["deltaStorageUrl"] = .string(
            JSString("\(endpoint)/deltas/tinylicious/\(createNew ? id : encoded)"))
        endpoints["ordererUrl"] = .string(JSString(endpoint))
        endpoints["storageUrl"] = .string(JSString("\(endpoint)/repos/tinylicious"))
        var result = JSObject<JSONValue>()
        result["endpoints"] = .object(endpoints)
        result["id"] = .string(JSString(id))
        result["tokens"] = .object(.init())
        result["type"] = .string("fluid")
        result["url"] = .string(
            JSString(
                "\(endpoint)/tinylicious/\(createNew ? id : encoded + relative.dropFirst(first.count))"
            ))
        return try IResolvedUrl(json: .object(result))
    }
    public func getAbsoluteUrl(_ resolved: IResolvedUrl, relative: String) throws -> String {
        let url = resolved.url.description
        let path = url.replacingOccurrences(of: endpoint + "/tinylicious/", with: "")
        guard let document = path.removingPercentEncoding else {
            throw JSONDecodingError("invalid URI encoding")
        }
        return document + "/" + relative
    }

}
