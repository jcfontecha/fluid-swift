import Testing
import FluidDriverBase
@testable import FluidRouterliciousDriver
import FluidJS
import FluidDriverDefinitions

struct RemoteServiceTests {
    @Test func testHTTPBackoffReachesSixtySeconds() throws {
        let http = DriverError("REST", try JSON.parse(#"{"code":500,"endpointReached":true}"#))
        #expect(calculateMaxWaitTime(8000, error: http) == 16000)
        #expect(calculateMaxWaitTime(40000, error: http) == 60000)
        let socket = DriverError("socket", try JSON.parse(#"{"code":500}"#))
        #expect(calculateMaxWaitTime(8000, error: socket) == 8000)
    }

    @Test func testWholeSnapshotPreservesProtocolAndDecodesBlobs() throws {
        let raw = try JSON.parse(#"{"id":"summary","trees":[{"id":"tree","sequenceNumber":4,"entries":[{"path":".app","type":"tree"},{"path":".app/a%20b","type":"blob","id":"b"},{"path":".protocol","type":"tree"},{"path":".protocol/attributes","type":"blob","id":"p"}]}],"blobs":[{"id":"b","content":"AP8=","encoding":"base64"},{"id":"p","content":"{}"}]}"#)
        let snapshot = try convertWholeFlatSnapshotToSnapshotTreeAndBlobs(raw)
        #expect(snapshot.id == "summary")
        #expect(snapshot.snapshotTree.blobs["a b"] == "b")
        #expect(snapshot.snapshotTree.trees[".protocol"]?.blobs["attributes"] == "p")
        #expect(snapshot.blobs["b"] == [0, 255])
        #expect(snapshot.blobs["p"] == [123, 125])
    }

    @Test func testDiscoveryReplacesHostsNotStoragePaths() throws {
        let resolved = try IResolvedUrl(json: JSON.parse(#"{"type":"fluid","id":"doc","url":"http://old/tenant/doc?q=1","tokens":{},"endpoints":{"ordererUrl":"http://old","deltaStorageUrl":"http://old/deltas/tenant/doc","storageUrl":"http://old/repos/tenant"}}"#))
        let session = try JSON.parse(#"{"ordererUrl":"http://new:7090","historianUrl":"http://store:7089/ignored","deltaStreamUrl":"http://socket:7090"}"#)
        let discovered = try getDiscoveredFluidResolvedUrl(resolved, session: session)
        #expect(discovered.url == "https://new:7090/tenant/doc")
        #expect(discovered.endpoints["storageUrl"] == "http://store:7089/repos/tenant")
        #expect(discovered.endpoints["deltaStorageUrl"] == "http://new:7090/deltas/tenant/doc")
    }
}
