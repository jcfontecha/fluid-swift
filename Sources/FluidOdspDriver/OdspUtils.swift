import FluidDriverDefinitions
import FluidJS
import Foundation

// Ports the parts of odsp-driver/src/odspUtils.ts and getUrlAndHeadersWithAuth.ts used by the
// document service and create-new paths.

/// 80KB is the max body size the server accepts in a ump post body; TS keeps 78KB.
public let maxUmpPostBodySize = 79872

/// getJoinSessionCacheKey.
public func getJoinSessionCacheKey(_ odspResolvedUrl: IOdspResolvedUrl) -> String {
    odspResolvedUrl.hashedDocumentId + "/joinsession"
}

/// tryGetNewFilePath: the folder path of a create-new request (`""` is the drive root).
func tryGetNewFilePath(_ searchParams: URLSearchParams) -> String? {
    searchParams.get("path")
}

/// tryGetNewFileParentFolderId: an empty ID is returned as is so callers can reject it.
func tryGetNewFileParentFolderId(_ searchParams: URLSearchParams) -> String? {
    searchParams.get("parentFolderId")
}

/// NewFileLocation: exactly one of a folder path or a parent folder item ID.
public enum NewFileLocation: Sendable {
    case filePath(String)
    case parentFolderId(String)
}

/// INewFileInfo.
public struct INewFileInfo: Sendable {
    public let siteUrl: String
    public let driveId: String
    public let location: NewFileLocation
    public let filename: String
}

/// IExistingFileInfo.
public struct IExistingFileInfo: Sendable {
    public let siteUrl: String
    public let driveId: String
    public let itemId: String
}

/// getUrlAndHeadersWithAuth.ts getHeadersWithAuth (0x936: the header must be non-empty).
func getHeadersWithAuth(_ authHeader: String) throws -> [String: String] {
    guard !authHeader.isEmpty else { throw JSONDecodingError("0x936") }
    return ["Authorization": authHeader]
}

/// odspUtils.ts tokenFromResponse for the websocket fetcher (toInstrumentedOdspTokenFetcher with
/// returnPlainToken): host failures become a non-retryable fetchTokenError.
public func plainTokenFetcher(_ tokenFetcher: @escaping TokenFetcher, resolvedUrl: IOdspResolvedUrl) -> @Sendable (TokenFetchOptions) async throws -> String? {
    { options in
        var options = options
        options.siteUrl = resolvedUrl.siteUrl
        options.driveId = resolvedUrl.driveId
        options.itemId = resolvedUrl.itemId
        do { return try await tokenFetcher(options).token }
        catch { throw OdspNetworkError("fetchTokenError", canRetry: false) }
    }
}
