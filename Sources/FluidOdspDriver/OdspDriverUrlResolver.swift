import CryptoKit
import FluidDriverDefinitions
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

/// WHATWG URLSearchParams parsing (application/x-www-form-urlencoded): `+` is a space and invalid
/// percent sequences stay as they are. `get` returns the first value for a name.
struct URLSearchParams {
    private var pairs: [(name: String, value: String)] = []
    init(_ query: String) {
        for sequence in query.split(separator: "&", omittingEmptySubsequences: true) {
            let split = sequence.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = Self.decode(split.first.map(String.init) ?? "")
            let value = Self.decode(split.count > 1 ? String(split[1]) : "")
            pairs.append((name, value))
        }
    }
    func get(_ name: String) -> String? {
        pairs.first { $0.name == name }?.value
    }
    private static func decode(_ text: String) -> String {
        var bytes: [UInt8] = []
        let input = Array(text.replacingOccurrences(of: "+", with: " ").utf8)
        var index = 0
        while index < input.count {
            if input[index] == 0x25, index + 2 < input.count, let byte = UInt8(String(decoding: input[index + 1...index + 2], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// `decodeURIComponent`: a malformed escape is a URIError.
func decodeURIComponent(_ value: String) throws -> String {
    guard let decoded = value.removingPercentEncoding else { throw JSONDecodingError("URIError: URI malformed") }
    return decoded
}

/// odsp-driver-definitions/src/resolvedUrl.ts IOdspResolvedUrl: the typed view of an ODSP
/// `IResolvedUrl`. The JSON object is the single source of truth and keeps TS property order
/// (a resolve result, a create-new result and later mutations each have their own order).
public struct IOdspResolvedUrl: DriverJSONValue {
    public let json: JSONValue
    /// The contract view (`IOdspResolvedUrl extends IResolvedUrl`).
    public let resolvedUrl: IResolvedUrl
    public let siteUrl: String
    public let driveId: String
    public let itemId: String
    public let dataStorePath: String?
    public let hashedDocumentId: String
    public let fileName: String
    public let summarizer: Bool
    public let snapshotStorageUrl: String
    public let deltaStorageUrl: String
    public let attachmentPOSTStorageUrl: String
    public let attachmentGETStorageUrl: String
    public let fileVersion: String?
    public let containerPackageName: String?
    public let isClpCompliantApp: Bool?
    public let eTag: String?
    public let pendingRename: String?

    /// odspUtils.ts getOdspResolvedUrl: asserts `odspResolvedUrl === true` (0x1de).
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        guard object["odspResolvedUrl"] == .bool(true) else { throw JSONDecodingError("0x1de") }
        resolvedUrl = try IResolvedUrl(json: json)
        let endpoints = try json.member("endpoints")
        siteUrl = try json.member("siteUrl").asString().description
        driveId = try json.member("driveId").asString().description
        itemId = try json.member("itemId").asString().description
        dataStorePath = try object["dataStorePath"].map { try $0.asString().description }
        hashedDocumentId = try json.member("hashedDocumentId").asString().description
        fileName = try json.member("fileName").asString().description
        summarizer = object["summarizer"] == .bool(true)
        snapshotStorageUrl = try endpoints.member("snapshotStorageUrl").asString().description
        deltaStorageUrl = try endpoints.member("deltaStorageUrl").asString().description
        attachmentPOSTStorageUrl = try endpoints.member("attachmentPOSTStorageUrl").asString().description
        attachmentGETStorageUrl = try endpoints.member("attachmentGETStorageUrl").asString().description
        fileVersion = try object["fileVersion"].map { try $0.asString().description }
        containerPackageName = try object["codeHint"]?.asObject()["containerPackageName"].map { try $0.asString().description }
        if case .bool(let flag) = object["isClpCompliantApp"] { isClpCompliantApp = flag } else { isClpCompliantApp = nil }
        eTag = try object["fileMetadata"]?.asObject()["eTag"].map { try $0.asString().description }
        pendingRename = try object["pendingRename"].map { try $0.asString().description }
        self.json = json
    }

    /// JS property assignment on the resolved-URL object: an existing key keeps its position, a new
    /// key is appended. `nil` is assignment of `undefined` (JSON.stringify omits the key).
    public func setting(_ key: JSString, _ value: JSONValue?) throws -> IOdspResolvedUrl {
        var object = try json.asObject()
        object[key] = value
        return try IOdspResolvedUrl(json: .object(object))
    }
}

/// odspUtils.ts getOdspResolvedUrl.
public func getOdspResolvedUrl(_ resolvedUrl: IResolvedUrl) throws -> IOdspResolvedUrl {
    try IOdspResolvedUrl(json: resolvedUrl.json)
}

/// createOdspUrl.ts.
public func createOdspUrl(siteUrl: String, driveId: String, itemId: String, dataStorePath: String, containerPackageName: String? = nil, fileVersion: String? = nil) -> String {
    var url = siteUrl + "?driveId=" + encodeOdspComponent(driveId) + "&itemId=" + encodeOdspComponent(itemId) + "&path=" + encodeOdspComponent(dataStorePath)
    if let containerPackageName, !containerPackageName.isEmpty { url += "&containerPackageName=" + encodeOdspComponent(containerPackageName) }
    if let fileVersion, !fileVersion.isEmpty { url += "&fileVersion=" + encodeOdspComponent(fileVersion) }
    return url
}

/// odspDriverUrlResolver.ts decodeOdspUrl: URLSearchParams decoding, then decodeURIComponent again.
func decodeOdspUrl(_ url: String) throws -> (siteUrl: String, driveId: String, itemId: String, path: String, containerPackageName: String?, fileVersion: String?) {
    let parts = url.components(separatedBy: "?")
    let searchParams = URLSearchParams(parts.count > 1 ? parts[1] : "")
    guard let driveId = searchParams.get("driveId") else { throw JSONDecodingError("ODSP URL did not contain a drive id") }
    guard let itemId = searchParams.get("itemId") else { throw JSONDecodingError("ODSP Url did not contain an item id") }
    guard let path = searchParams.get("path") else { throw JSONDecodingError("ODSP Url did not contain a path") }
    let containerPackageName = try searchParams.get("containerPackageName").flatMap { $0.isEmpty ? nil : try decodeURIComponent($0) }
    let fileVersion = try searchParams.get("fileVersion").flatMap { $0.isEmpty ? nil : try decodeURIComponent($0) }
    return (parts[0], try decodeURIComponent(driveId), try decodeURIComponent(itemId), try decodeURIComponent(path), containerPackageName, fileVersion)
}

/// odspDriverUrlResolver.ts.
public struct OdspDriverUrlResolver: IUrlResolver {
    public init() {}

    public func resolve(_ request: IRequest) async throws -> IResolvedUrl? {
        try resolveOdspUrl(request).resolvedUrl
    }

    /// The typed result of `resolve` for a plain ODSP URL.
    public func resolve(_ url: String) throws -> IOdspResolvedUrl {
        try resolveOdspUrl(IRequest(url: url))
    }

    func resolveOdspUrl(_ request: IRequest) throws -> IOdspResolvedUrl {
        let isClpCompliantApp = request.headers?["X-CLP-Compliant-App"]
        if let createNew = request.headers?["createNew"], createNew != .null, createNew != .bool(false) {
            return try resolveCreateNew(request, createNew: createNew, isClpCompliantApp: isClpCompliantApp)
        }
        let decoded = try decodeOdspUrl(request.url)
        let hash = encodeOdspComponent(Data(SHA256.hash(data: Data((decoded.driveId + "_" + decoded.itemId).utf8))).base64EncodedString())
        guard !hash.contains("/") else { throw JSONDecodingError("0x0a8") }
        let path = decoded.path.hasPrefix("/") ? String(decoded.path.dropFirst()) : decoded.path
        let version = decoded.fileVersion.map { "versions/" + $0 + "/" } ?? ""
        let urlBase = try getApiRoot(decoded.siteUrl) + "/drives/" + decoded.driveId + "/items/" + decoded.itemId + "/" + version
        var endpoints = JSObject<JSONValue>()
        endpoints["snapshotStorageUrl"] = .string(JSString(urlBase + "opStream/snapshots"))
        endpoints["attachmentPOSTStorageUrl"] = .string(JSString(urlBase + "opStream/attachment"))
        endpoints["attachmentGETStorageUrl"] = .string(JSString(urlBase + "opStream/attachments"))
        endpoints["deltaStorageUrl"] = .string(JSString(urlBase + "opStream"))
        var codeHint = JSObject<JSONValue>()
        codeHint["containerPackageName"] = decoded.containerPackageName.map { .string(JSString($0)) }
        var fileMetadata = JSObject<JSONValue>()
        fileMetadata["eTag"] = request.headers?["eTag"]
        var object = JSObject<JSONValue>()
        object["type"] = .string("fluid")
        object["odspResolvedUrl"] = .bool(true)
        object["endpoints"] = .object(endpoints)
        object["id"] = .string(JSString(hash))
        object["tokens"] = .object(JSObject())
        object["url"] = .string(JSString("https://placeholder/placeholder/" + hash + "/" + path))
        object["hashedDocumentId"] = .string(JSString(hash))
        object["siteUrl"] = .string(JSString(decoded.siteUrl))
        object["driveId"] = .string(JSString(decoded.driveId))
        object["itemId"] = .string(JSString(decoded.itemId))
        object["dataStorePath"] = .string(JSString(decoded.path))
        object["fileName"] = .string("")
        object["summarizer"] = .bool(isTruthy(request.headers?["fluid-client-summarizer"]))
        object["codeHint"] = .object(codeHint)
        object["fileVersion"] = decoded.fileVersion.map { .string(JSString($0)) }
        object["isClpCompliantApp"] = isClpCompliantApp
        object["fileMetadata"] = .object(fileMetadata)
        return try IOdspResolvedUrl(json: .object(object))
    }

    private func resolveCreateNew(_ request: IRequest, createNew: JSONValue, isClpCompliantApp: JSONValue?) throws -> IOdspResolvedUrl {
        let parts = request.url.components(separatedBy: "?")
        let siteUrl = parts[0]
        let queryString = parts.count > 1 ? parts[1] : "undefined"
        let searchParams = URLSearchParams(queryString)
        let fileName = try createNew.asObject()["fileName"]
        let driveId = searchParams.get("driveId")
        let filePath = tryGetNewFilePath(searchParams)
        let parentFolderId = tryGetNewFileParentFolderId(searchParams)
        let packageName = searchParams.get("containerPackageName")
        let hasValidFolder = parentFolderId == nil ? filePath != nil : filePath == nil && parentFolderId != ""
        guard case .string(let name) = fileName, !name.description.isEmpty, !siteUrl.isEmpty, let driveId, !driveId.isEmpty, hasValidFolder else {
            throw OdspNetworkError("genericError", canRetry: false)
        }
        var endpoints = JSObject<JSONValue>()
        endpoints["snapshotStorageUrl"] = .string("")
        endpoints["attachmentGETStorageUrl"] = .string("")
        endpoints["attachmentPOSTStorageUrl"] = .string("")
        endpoints["deltaStorageUrl"] = .string("")
        var codeHint = JSObject<JSONValue>()
        codeHint["containerPackageName"] = packageName.map { .string(JSString($0)) }
        var object = JSObject<JSONValue>()
        object["endpoints"] = .object(endpoints)
        object["tokens"] = .object(JSObject())
        object["type"] = .string("fluid")
        object["odspResolvedUrl"] = .bool(true)
        object["id"] = .string("odspCreateNew")
        // TS prefixes "https://" to a siteUrl that already carries its scheme.
        object["url"] = .string(JSString("https://" + siteUrl + "?" + queryString + "&version=null"))
        object["siteUrl"] = .string(JSString(siteUrl))
        object["hashedDocumentId"] = .string("")
        object["driveId"] = .string(JSString(driveId))
        object["itemId"] = .string("")
        object["fileName"] = .string(name)
        object["summarizer"] = .bool(false)
        object["codeHint"] = .object(codeHint)
        object["isClpCompliantApp"] = isClpCompliantApp
        return try IOdspResolvedUrl(json: .object(object))
    }

    public func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String {
        getAbsoluteUrl(try getOdspResolvedUrl(resolvedUrl), relativeUrl: relativeUrl)
    }

    public func getAbsoluteUrl(_ resolved: IOdspResolvedUrl, relativeUrl: String) -> String {
        var dataStorePath = relativeUrl
        if relativeUrl.isEmpty, let path = resolved.dataStorePath { dataStorePath = path }
        if dataStorePath.hasPrefix("/") { dataStorePath = String(dataStorePath.dropFirst()) }
        return createOdspUrl(siteUrl: resolved.siteUrl, driveId: resolved.driveId, itemId: resolved.itemId, dataStorePath: dataStorePath, containerPackageName: resolved.containerPackageName, fileVersion: resolved.fileVersion)
    }
}

/// JS truthiness of a header value (`!!request.headers?.[name]`).
func isTruthy(_ value: JSONValue?) -> Bool {
    switch value {
    case nil, .null: return false
    case .bool(let flag): return flag
    case .number(let number): return number != 0 && !number.isNaN
    case .string(let text): return !text.description.isEmpty
    case .array, .object: return true
    }
}

/// odspLocationRedirection.ts. Only the site origin changes; endpoints and authored path stay intact.
public func patchOdspResolvedUrl(_ resolved: IOdspResolvedUrl, redirectLocation: String) throws -> IOdspResolvedUrl {
    guard var destination = URLComponents(string: redirectLocation),
          let scheme = destination.scheme, destination.host != nil,
          let original = URLComponents(string: resolved.siteUrl) else { throw JSONDecodingError("invalid redirect URL") }
    destination.user = nil
    destination.password = nil
    if (scheme == "https" && destination.port == 443) || (scheme == "http" && destination.port == 80) { destination.port = nil }
    destination.percentEncodedPath = original.percentEncodedPath.isEmpty ? "/" : original.percentEncodedPath
    destination.query = nil
    destination.fragment = nil
    guard let siteUrl = destination.string else { throw JSONDecodingError("invalid redirect site URL") }
    return try resolved.setting("siteUrl", .string(JSString(siteUrl)))
}
