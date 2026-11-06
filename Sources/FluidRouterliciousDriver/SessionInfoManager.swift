import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

/// Ports urlUtils.ts: replace hosts, preserve the configured historian and delta paths.
public func getDiscoveredFluidResolvedUrl(_ resolvedUrl: IResolvedUrl, session: JSONValue) throws -> IResolvedUrl {
    let orderer = try session.member("ordererUrl").asString().description
    let historian = try session.member("historianUrl").asString().description
    func replacingHost(_ value: String, from discovered: String) throws -> String {
        guard var target = URLComponents(string: value), let source = URLComponents(string: discovered) else {
            throw JSONDecodingError("Invalid discovery URL")
        }
        target.host = source.host
        target.port = source.port
        return target.string!
    }
    var endpoints = JSObject<JSONValue>()
    endpoints["deltaStorageUrl"] = .string(JSString(try replacingHost(resolvedUrl.endpoints["deltaStorageUrl"]!.description, from: orderer)))
    endpoints["ordererUrl"] = .string(JSString(orderer))
    if let stream = try session.asObject()["deltaStreamUrl"] { endpoints["deltaStreamUrl"] = stream }
    endpoints["storageUrl"] = .string(JSString(try replacingHost(resolvedUrl.endpoints["storageUrl"]!.description, from: historian)))
    var result = JSObject<JSONValue>()
    result["endpoints"] = .object(endpoints)
    result["id"] = .string(resolvedUrl.id)
    result["tokens"] = try resolvedUrl.json.member("tokens")
    result["type"] = .string("fluid")
    var url = URLComponents(string: orderer)!
    url.scheme = "https"
    url.percentEncodedPath = URLComponents(string: resolvedUrl.url.description)!.percentEncodedPath
    url.query = nil
    url.fragment = nil
    result["url"] = .string(JSString(url.string!))
    return try IResolvedUrl(json: .object(result))
}

/// Ports sessionInfoManager.ts, including the five-minute rediscovery window.
final class SessionInfoManager: Sendable {
    private let enabled: Bool
    private let sessions = Mutex<[String: (IResolvedUrl, Date)]>([:])
    init(enabled: Bool) { self.enabled = enabled }

    func initialize(_ url: IResolvedUrl, tenant: String, document: String, rest: RestClient, session: JSONValue?) async throws -> IResolvedUrl {
        let key = discoveryUrl(url, tenant, document)
        let initial = try session.map { try getDiscoveredFluidResolvedUrl(url, session: $0) }
        sessions.withLock { entries in
            if let initial { entries[key] = (initial, Date()) }
            else if entries[key] == nil { entries[key] = (url, .distantPast) }
        }
        return try await get(url, tenant: tenant, document: document, rest: rest).0
    }

    func get(_ url: IResolvedUrl, tenant: String, document: String, rest: RestClient) async throws -> (IResolvedUrl, Bool) {
        let key = discoveryUrl(url, tenant, document)
        let cached = sessions.withLock { $0[key]! }
        guard enabled, Date().timeIntervalSince(cached.1) > 300 else { return (cached.0, false) }
        do {
            let session = try await rest.get(key)
            let discovered = try getDiscoveredFluidResolvedUrl(url, session: session)
            sessions.withLock { $0[key] = (discovered, Date()) }
            return (discovered, true)
        } catch {
            sessions.withLock { $0[key] = (cached.0, .distantPast) }
            throw error
        }
    }

    private func discoveryUrl(_ url: IResolvedUrl, _ tenant: String, _ document: String) -> String {
        "\(url.endpoints["ordererUrl"]!)/documents/\(tenant)/session/\(document)"
    }
}
