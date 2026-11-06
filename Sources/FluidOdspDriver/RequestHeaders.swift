import Foundation

/// requestHeaders.ts. Driver-owned protocol headers cannot be supplied by the host.
public func copyRequestHeaders(_ headers: [String: String]?) -> [String: String]? {
    guard let headers else { return nil }
    let forbidden: Set<String> = ["authorization", "content-type", "x-fluid-epoch", "x-http-method-override", "x-requeststats"]
    let safe = headers.filter { !forbidden.contains($0.key.lowercased()) }
    return safe.isEmpty ? nil : safe
}

public func mergeRequestHeaders(_ host: [String: String]?, _ driver: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in host ?? [:] { result[key.lowercased()] = value }
    for (key, value) in driver { result[key.lowercased()] = value }
    return result
}
