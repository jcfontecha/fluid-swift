import FluidDriverDefinitions
import FluidJS
import Testing
@testable import FluidOdspDriver

// Expected texts are JSON.stringify output of the installed 3.11.0 TS driver for the same inputs.

struct OdspResolvedUrlShapeTests {
    @Test func existingFileResolveMatchesTSPropertyOrder() async throws {
        let url = "https://contoso.sharepoint.com/sites/a?driveId=b%21Drive&itemId=Item&path=%2Fstore&containerPackageName=pkg&fileVersion=v1"
        let resolved = try #require(try await OdspDriverUrlResolver().resolve(IRequest(url: url)))
        #expect(JSON.stringify(resolved.json) == #"{"type":"fluid","odspResolvedUrl":true,"endpoints":{"snapshotStorageUrl":"https://contoso.sharepoint.com/_api/v2.1/drives/b!Drive/items/Item/versions/v1/opStream/snapshots","attachmentPOSTStorageUrl":"https://contoso.sharepoint.com/_api/v2.1/drives/b!Drive/items/Item/versions/v1/opStream/attachment","attachmentGETStorageUrl":"https://contoso.sharepoint.com/_api/v2.1/drives/b!Drive/items/Item/versions/v1/opStream/attachments","deltaStorageUrl":"https://contoso.sharepoint.com/_api/v2.1/drives/b!Drive/items/Item/versions/v1/opStream"},"id":"1Yytdn6U2fcQe20FJNgd5VSHT0zFO9YYWS3BunaUSPY%3D","tokens":{},"url":"https://placeholder/placeholder/1Yytdn6U2fcQe20FJNgd5VSHT0zFO9YYWS3BunaUSPY%3D/store","hashedDocumentId":"1Yytdn6U2fcQe20FJNgd5VSHT0zFO9YYWS3BunaUSPY%3D","siteUrl":"https://contoso.sharepoint.com/sites/a","driveId":"b!Drive","itemId":"Item","dataStorePath":"/store","fileName":"","summarizer":false,"codeHint":{"containerPackageName":"pkg"},"fileVersion":"v1","fileMetadata":{}}"#)
        let typed = try getOdspResolvedUrl(resolved)
        #expect(typed.containerPackageName == "pkg")
        #expect(typed.fileVersion == "v1")
    }

    @Test func createNewRequestAndResolveMatchTS() async throws {
        let request = createOdspCreateContainerRequest(siteUrl: "https://contoso.sharepoint.com/sites/a", driveId: "b!Drive", filePath: "/folder", fileName: "name")
        #expect(request.url == "https://contoso.sharepoint.com/sites/a?driveId=b!Drive&path=%2Ffolder")
        let resolved = try #require(try await OdspDriverUrlResolver().resolve(request))
        // TS prefixes "https://" to a site URL that already has a scheme.
        #expect(JSON.stringify(resolved.json) == #"{"endpoints":{"snapshotStorageUrl":"","attachmentGETStorageUrl":"","attachmentPOSTStorageUrl":"","deltaStorageUrl":""},"tokens":{},"type":"fluid","odspResolvedUrl":true,"id":"odspCreateNew","url":"https://https://contoso.sharepoint.com/sites/a?driveId=b!Drive&path=%2Ffolder&version=null","siteUrl":"https://contoso.sharepoint.com/sites/a","hashedDocumentId":"","driveId":"b!Drive","itemId":"","fileName":"name","summarizer":false,"codeHint":{}}"#)
    }

    @Test func nonOdspResolvedUrlIsRejected() throws {
        let plain = try IResolvedUrl(json: JSON.parse(#"{"type":"fluid","id":"x","url":"u","tokens":{},"endpoints":{}}"#))
        #expect(throws: JSONDecodingError.self) { try getOdspResolvedUrl(plain) }
    }

    @Test func settingKeepsExistingPositionAndAppendsNewKeys() throws {
        let resolved = try OdspDriverUrlResolver().resolve("https://t.sharepoint.com/?driveId=d&itemId=i&path=")
        let renamed = try resolved.setting("fileName", .string("renamed")).setting("pendingRename", .string("p"))
        let keys = try renamed.json.asObject().keys.map(\.description)
        #expect(keys.firstIndex(of: "fileName") == (try resolved.json.asObject().keys.map(\.description).firstIndex(of: "fileName")))
        #expect(keys.last == "pendingRename")
        #expect(renamed.pendingRename == "p")
    }
}

struct OdspCreateNewTests {
    private let summaryText = #"{"type":1,"tree":{".app":{"type":1,"tree":{"b":{"type":2,"content":{"0":1,"1":2}},"t":{"type":1,"tree":{},"unreferenced":true,"groupId":"g"}}},".protocol":{"type":1,"tree":{"attributes":{"type":2,"content":"{ \"sequenceNumber\": 0, \"minimumSequenceNumber\": 0, \"term\": 1 }"}}}}}"#

    @Test func containerSnapshotPutsProtocolFirstAndReserializesAttributes() throws {
        let summary = try ISummaryTree(json: JSON.parse(summaryText))
        let (payload, mutated) = try convertSummaryIntoContainerSnapshot(summary)
        #expect(JSON.stringify(payload) == #"{"entries":[{"path":".protocol","type":"tree","value":{"type":"tree","entries":[{"path":"attributes","type":"blob","value":{"type":"blob","content":"{\"sequenceNumber\":0,\"minimumSequenceNumber\":0,\"term\":1}","encoding":"utf-8"}}]}},{"path":".app","type":"tree","value":{"type":"tree","entries":[{"path":"b","type":"blob","value":{"type":"blob","content":"AQI=","encoding":"base64"}},{"path":"t","type":"tree","value":{"type":"tree","entries":[]},"unreferenced":true,"groupId":"g"}]}}],"message":"app","sequenceNumber":0,"type":"container"}"#)
        // TS mutates the caller's protocol tree in place; key order of the summary is unchanged.
        #expect(JSON.stringify(mutated.json) == #"{"type":1,"tree":{".app":{"type":1,"tree":{"b":{"type":2,"content":{"0":1,"1":2}},"t":{"type":1,"tree":{},"unreferenced":true,"groupId":"g"}}},".protocol":{"type":1,"tree":{"attributes":{"type":2,"content":"{\"sequenceNumber\":0,\"minimumSequenceNumber\":0,\"term\":1}"}}}}}"#)
    }

    @Test func cachedCreateNewSnapshotUsesFreshBlobIds() throws {
        let summary = try ISummaryTree(json: JSON.parse(summaryText))
        let snapshot = try convertCreateNewSummaryTreeToTreeAndBlobs(summary, treeId: "handle")
        #expect(snapshot.snapshotTree.id == "handle")
        #expect(snapshot.sequenceNumber == 0)
        #expect(snapshot.latestSequenceNumber == 0)
        #expect(snapshot.blobContents.size == 2)
        let appBlob = try #require(snapshot.snapshotTree.trees[".app"]?.blobs["b"])
        #expect(snapshot.blobContents.get(appBlob) == .buffer([1, 2][...]))
        #expect(snapshot.snapshotTree.trees[".app"]?.trees["t"]?.groupId == "g")
    }

    @Test func handlesCannotBeInACreateNewSummary() throws {
        let summary = try ISummaryTree(json: JSON.parse(#"{"type":1,"tree":{".app":{"type":1,"tree":{"h":{"type":3,"handleType":2,"handle":"/x"}}},".protocol":{"type":1,"tree":{"attributes":{"type":2,"content":"{\"sequenceNumber\":0}"}}}}}"#))
        #expect(throws: JSONDecodingError.self) { try convertSummaryIntoContainerSnapshot(summary) }
    }
}
