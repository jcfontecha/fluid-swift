import Foundation
import Testing
import FluidJS
import FluidDriverDefinitions
import FluidContainerRuntime
import FluidDatastore
import FluidMap
import FluidStatic

struct M2SnapshotTests {
    @Test func loadsCapturedTypeScriptSummary() throws {
        let url = try #require(Bundle.module.url(forResource: "m2-summary", withExtension: "json", subdirectory: "Fixtures"))
        let snapshot = try SummaryTree(json: JSON.parse(String(contentsOf: url, encoding: .utf8)))
        let runtime = try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "test")
        try runtime.loadSnapshot(snapshot, factories: [
            ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"),
            ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"),
        ])
        let root = try RootDataObject(runtime: runtime)
        let map = try #require(root.initialObjects["map"] as? SharedMap)
        #expect(map.get("captured") == (try JSON.parse("{\"seed\":0,\"nested\":[null,true,\"hello\"]}")))
        let protocolTree = try SummaryTree(json: snapshot.json.member("tree").member(".protocol"))
        #expect(runtime.referenceSequenceNumber == (try protocolTree.readAndParse("attributes").member("sequenceNumber").asInt()))
        #expect(runtime.channelCollection.datastoreIds == ["A"])
    }
}

extension M2SnapshotTests {
    private func captured(_ name: String = "m2-summary") throws -> SummaryTree {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try SummaryTree(json: JSON.parse(String(contentsOf: url, encoding: .utf8)))
    }

    private func runtime() throws -> ContainerRuntime {
        try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "test")
    }

    private var factories: [ChannelFactory] {
        [ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"),
         ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1")]
    }

    @Test func loadsCapturedAttachSummary() throws {
        let runtime = try runtime()
        try runtime.loadSnapshot(captured("m2-attach"), factories: factories)
        let root = try RootDataObject(runtime: runtime)
        let map = try #require(root.initialObjects["map"] as? SharedMap)
        #expect(map.size == 0)
        #expect(runtime.referenceSequenceNumber == 0)
    }

    @Test func rejectsMismatchedProtocolReference() throws {
        guard case .tree(let tree) = try captured() else { return }
        var entries = tree.tree
        var metadata = try SummaryTree.tree(tree).readAndParse(".metadata").asObject()
        var last = try #require(metadata["lastMessage"]).asObject()
        last["sequenceNumber"] = .number(999)
        metadata["lastMessage"] = .object(last)
        entries[".metadata"] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(.object(metadata))))))
        #expect(throws: JSONDecodingError.self) {
            try runtime().loadSnapshot(SummaryTree(tree: entries), factories: factories)
        }
    }

    @Test func loadsOptionalRuntimeStateAndRejectsMissingRootAlias() throws {
        guard case .tree(let tree) = try captured() else { return }
        var entries = tree.tree
        let election = "{\"electionSequenceNumber\":4,\"electedClientId\":\"test\"}"
        entries[".electedSummarizer"] = .blob(ISummaryBlob(content: .text(JSString(election))))
        var blobs = JSObject<SummaryObject>()
        blobs["storage"] = .attachment(try ISummaryAttachment(json: JSON.parse("{\"type\":4,\"id\":\"storage\"}")))
        blobs[".redirectTable"] = .blob(ISummaryBlob(content: .text("[[\"local\",\"storage\"]]")))
        entries[".blobs"] = .tree(ISummaryTree(tree: blobs))
        entries[".aliases"] = .blob(ISummaryBlob(content: .text("[]")))
        let runtime = try runtime()
        try runtime.loadSnapshot(SummaryTree(tree: entries), factories: factories)
        #expect(runtime.blobManager.hasBlob("local"))
        #expect(runtime.blobManager.hasBlob("storage"))
        #expect(runtime.electedSummarizerData == (try JSON.parse(election)))
        #expect(runtime.gcSnapshot != nil)
        #expect(throws: DatastoreError.self) { try RootDataObject(runtime: runtime) }
    }
}
