import FluidDriverDefinitions
import FluidJS

/// The TS union `ISnapshot | ISnapshotTree` that container load fetches.
enum FetchedSnapshot {
    case snapshot(ISnapshot)
    case tree(ISnapshotTree)

    /// driver-utils `getSnapshotTree`.
    var snapshotTree: ISnapshotTree {
        switch self {
        case .snapshot(let snapshot): snapshot.snapshotTree
        case .tree(let tree): tree
        }
    }
}

/// Ports serializedStateManager.ts `getSnapshot` (without pending local state): one ISnapshot when
/// the service supports getSnapshot, else the version's ISnapshotTree. assert 0x8e4: it must exist.
func getSnapshot(
    _ storage: any IDocumentStorageService, supportGetSnapshotApi: Bool, specifiedVersion: JSString?
) async throws -> (snapshot: FetchedSnapshot, version: IVersion?) {
    if supportGetSnapshotApi {
        let (snapshot, version) = try await fetchISnapshot(storage, specifiedVersion: specifiedVersion)
        return (.snapshot(snapshot), version)
    }
    let (snapshot, version) = try await fetchISnapshotTree(storage, specifiedVersion: specifiedVersion)
    guard let snapshot else { throw JSONDecodingError("0x8e4: Snapshot should exist") }
    return (.tree(snapshot), version)
}

/// Ports serializedStateManager.ts `fetchISnapshot`: the version is the snapshot tree's id.
func fetchISnapshot(_ storage: any IDocumentStorageService, specifiedVersion: JSString?) async throws
    -> (snapshot: ISnapshot, version: IVersion?)
{
    var options = JSObject<JSONValue>()
    if let specifiedVersion { options["versionId"] = .string(specifiedVersion) }
    let snapshot = try await storage.getSnapshot(ISnapshotFetchOptions(json: .object(options)))
    guard let id = snapshot.snapshotTree.id else { return (snapshot, nil) }
    var version = JSObject<JSONValue>()
    version["id"] = .string(id)
    version["treeId"] = .string(id)
    return (snapshot, try IVersion(json: .object(version)))
}

/// Ports serializedStateManager.ts `fetchISnapshotTree`: the latest (or specified) version, then its tree.
func fetchISnapshotTree(_ storage: any IDocumentStorageService, specifiedVersion: JSString?) async throws
    -> (snapshot: ISnapshotTree?, version: IVersion?)
{
    let versions = try await storage.getVersions(specifiedVersion, count: 1, scenarioName: nil, fetchSource: nil)
    let version = versions.first
    let snapshot = try await storage.getSnapshotTree(version, scenarioName: nil)
    return (snapshot, version)
}
