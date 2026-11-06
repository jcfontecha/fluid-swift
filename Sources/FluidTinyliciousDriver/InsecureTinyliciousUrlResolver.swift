import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import Foundation

/// Ports tinylicious-driver/src/insecureTinyliciousUrlResolver.ts.
public struct InsecureTinyliciousUrlResolver: IUrlResolver {
    public let endpoint: String

    /// The endpoint's origin, with the port given, else its own, else 7070.
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

    /// A `createNew` request header asks for a new document; an empty id becomes "new", which
    /// lets the driver choose the id.
    public func resolve(_ request: IRequest) async throws -> IResolvedUrl? {
        let url = request.url
        let relativeUrl = url.replacingOccurrences(
            of: endpoint + "/", with: "", options: [], range: url.range(of: endpoint + "/"))
        let documentIdFromRequest = String(
            relativeUrl.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        let createNew = request.headers?["createNew"] == .bool(true)
        let finalDocumentId = createNew && documentIdFromRequest.isEmpty ? "new" : documentIdFromRequest
        let deltaStorageUrl: String
        let documentUrl: String
        if createNew {
            deltaStorageUrl = "\(endpoint)/deltas/tinylicious/\(finalDocumentId)"
            documentUrl = "\(endpoint)/tinylicious/\(finalDocumentId)"
        } else {
            let encodedDocId = encodeURIComponent(finalDocumentId)
            let documentRelativePath = relativeUrl.dropFirst(documentIdFromRequest.count)
            documentUrl = "\(endpoint)/tinylicious/\(encodedDocId)\(documentRelativePath)"
            deltaStorageUrl = "\(endpoint)/deltas/tinylicious/\(encodedDocId)"
        }
        var endpoints = JSObject<JSONValue>()
        endpoints["deltaStorageUrl"] = .string(JSString(deltaStorageUrl))
        endpoints["ordererUrl"] = .string(JSString(endpoint))
        endpoints["storageUrl"] = .string(JSString("\(endpoint)/repos/tinylicious"))
        var result = JSObject<JSONValue>()
        result["endpoints"] = .object(endpoints)
        result["id"] = .string(JSString(finalDocumentId))
        result["tokens"] = .object(.init())
        result["type"] = .string("fluid")
        result["url"] = .string(JSString(documentUrl))
        return try IResolvedUrl(json: .object(result))
    }

    /// A "URL" that resolves back to the same document: the decoded document path, then the
    /// relative URL.
    public func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String {
        let url = resolvedUrl.url.description
        let path = url.replacingOccurrences(of: endpoint + "/tinylicious/", with: "")
        guard let documentId = path.removingPercentEncoding else {
            throw JSONDecodingError("URIError: URI malformed")
        }
        return documentId + "/" + relativeUrl
    }
}
