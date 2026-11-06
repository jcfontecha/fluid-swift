import Testing
import FluidJS
@testable import FluidContainerRuntime

@Suite struct SummaryGenerationTests {
    @Test func graphCyclesAndMissingTargets() throws {
        let graph = try JSON.parse(#"{"gcNodes":{"/":["/a"],"/a":["/b","/missing"],"/b":["/a"],"/c":[]}}"#)
        let result = try runGarbageCollection(graph)
        #expect(result.referencedNodeIds == ["/", "/a", "/b"])
        #expect(result.deletedNodeIds == ["/c"])
    }
    @Test func trackingAndAcknowledgment() throws {
        let collector = GarbageCollector()
        let graph = try JSON.parse(#"{"gcNodes":{"/":["/a"],"/a":[],"/b":[]}}"#)
        try collector.collectGarbage(graph, timestamp: 100)
        let first = try collector.summarize(fullTree: false, trackState: true)
        #expect(try first.summary.readAndParse("__gc_root").member("gcNodes").member("/b").member("unreferencedTimestampMs") == .number(100))
        let unacked = try collector.summarize(fullTree: false, trackState: true)
        #expect(unacked.summary == first.summary)
        collector.refreshLatestSummary()
        let reused = try collector.summarize(fullTree: false, trackState: true)
        #expect(try reused.summary.json.member("handle") == .string("/gc"))
        let full = try collector.summarize(fullTree: true, trackState: true)
        #expect(full.summary == first.summary)
    }
    @Test func transientReferenceResetsAge() throws {
        let collector = GarbageCollector()
        let graph = try JSON.parse(#"{"gcNodes":{"/":[],"/b":["/c"],"/c":[]}}"#)
        try collector.collectGarbage(graph, timestamp: 100)
        collector.addedOutboundReference(from: "/", to: "/b")
        try collector.collectGarbage(graph, timestamp: 200)
        let summary = try collector.summarize(fullTree: true, trackState: false)
        #expect(try summary.summary.readAndParse("__gc_root").member("gcNodes").member("/c").member("unreferencedTimestampMs") == .number(200))
    }
}

@Suite struct SummarizerNodeTests {
    @Test func ackDoesNotConsumeLaterChanges() {
        let node = SummarizerNode()
        node.recordChange()
        node.trackSummary()
        node.recordChange()
        node.refreshLatestSummary()
        #expect(node.hasChanged)
        node.trackSummary()
        node.refreshLatestSummary()
        #expect(!node.hasChanged)
    }
    @Test func noAckDoesNotAdvanceBaseline() {
        let node = SummarizerNode()
        node.recordChange()
        node.trackSummary()
        #expect(node.hasChanged)
    }
}

@Suite struct SummaryFormatTests {
    @Test func utf8SummarySize() throws {
        let stats = try SummaryStats(.singleBlob("header", "🙂é"))
        #expect(stats.treeNodeCount == 1)
        #expect(stats.blobNodeCount == 1)
        #expect(stats.totalBlobSize == 6)
    }
    @Test func sortingDoesNotRewriteGraphOrRouteDuplicates() throws {
        let input = try JSON.parse(#"{"gcNodes":{"/B":{"outboundRoutes":["/z","/A","/A"]},"/a":{"outboundRoutes":[]}}}"#)
        let sorted = try generateSortedGCState(input)
        #expect(JSON.stringify(sorted) == #"{"gcNodes":{"/a":{"outboundRoutes":[]},"/B":{"outboundRoutes":["/A","/A","/z"]}}}"#)
        #expect(try input.member("gcNodes").asObject().keys == ["/B", "/a"])
    }
}
