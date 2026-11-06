import CryptoKit
import FluidJS
import Foundation

public func encodeOdspComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? value
}

public func getApiRoot(_ siteUrl: String) throws -> String {
    guard let parts = URLComponents(string: siteUrl), let scheme = parts.scheme, let host = parts.host else { throw JSONDecodingError("invalid site URL") }
    let origin = scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    let consumer = ["onedrive.com", "storage.live.com", "storage.live-int.com", "onedrive-tst.com"].contains { origin.hasSuffix($0) }
    return origin + (consumer ? "/v2.1" : "/_api/v2.1")
}

/// odsp-driver-definitions/src/resolvedUrl.ts.
public struct IOdspResolvedUrl: Sendable {
    public let siteUrl: String
    public let driveId: String
    public let itemId: String
    public let dataStorePath: String
    public let hashedDocumentId: String
    public let snapshotStorageUrl: String
    public let deltaStorageUrl: String
    public let attachmentPOSTStorageUrl: String
    public let attachmentGETStorageUrl: String
    public let fileVersion: String?
    public let containerPackageName: String?
}

public func createOdspUrl(siteUrl: String, driveId: String, itemId: String, dataStorePath: String, containerPackageName: String? = nil, fileVersion: String? = nil) -> String {
    var url = siteUrl + "?driveId=" + encodeOdspComponent(driveId) + "&itemId=" + encodeOdspComponent(itemId) + "&path=" + encodeOdspComponent(dataStorePath)
    if let containerPackageName, !containerPackageName.isEmpty { url += "&containerPackageName=" + encodeOdspComponent(containerPackageName) }
    if let fileVersion, !fileVersion.isEmpty { url += "&fileVersion=" + encodeOdspComponent(fileVersion) }
    return url
}

/// odspDriverUrlResolver.ts.
public struct OdspDriverUrlResolver {
    public init() {}
    public func resolve(_ url: String) throws -> IOdspResolvedUrl {
        let parts = url.components(separatedBy: "?")
        guard parts.count > 1 else { throw JSONDecodingError("missing drive id") }
        var query: [String: String] = [:]
        for pair in parts[1].components(separatedBy: "&") {
            let split = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = split.first else { continue }
            let raw = split.count > 1 ? String(split[1]) : ""
            guard let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw JSONDecodingError("invalid query encoding") }
            if query[String(key)] == nil { query[String(key)] = decoded }
        }
        func required(_ key: String) throws -> String {
            guard let value = query[key] else { throw JSONDecodingError("missing \(key)") }
            guard let decoded = value.removingPercentEncoding else { throw JSONDecodingError("invalid percent encoding") }
            return decoded
        }
        let drive = try required("driveId")
        let item = try required("itemId")
        let path = try required("path")
        let version = try query["fileVersion"].map { value in
            guard let decoded = value.removingPercentEncoding else { throw JSONDecodingError("invalid version") }
            return decoded
        }
        let hash = encodeOdspComponent(Data(SHA256.hash(data: Data((drive + "_" + item).utf8))).base64EncodedString())
        let root = try getApiRoot(parts[0]) + "/drives/" + drive + "/items/" + item + "/" + (version.flatMap { $0.isEmpty ? nil : "versions/" + $0 + "/" } ?? "") + "opStream"
        return IOdspResolvedUrl(siteUrl: parts[0], driveId: drive, itemId: item, dataStorePath: path, hashedDocumentId: hash, snapshotStorageUrl: root + "/snapshots", deltaStorageUrl: root, attachmentPOSTStorageUrl: root + "/attachment", attachmentGETStorageUrl: root + "/attachments", fileVersion: version, containerPackageName: query["containerPackageName"])
    }
    public func getAbsoluteUrl(_ resolved: IOdspResolvedUrl, relativeUrl: String) -> String {
        let path = relativeUrl.isEmpty ? resolved.dataStorePath : relativeUrl
        return createOdspUrl(siteUrl: resolved.siteUrl, driveId: resolved.driveId, itemId: resolved.itemId, dataStorePath: path.hasPrefix("/") ? String(path.dropFirst()) : path, containerPackageName: resolved.containerPackageName, fileVersion: resolved.fileVersion)
    }
}
