import XCTest
import FluidJS
import FluidDriverDefinitions
@testable import FluidContainerRuntime

final class SummaryGeneratorTests: XCTestCase {
    private func message(_ type: String, _ sequence: Int, _ contents: String) throws -> ISequencedDocumentMessage {
        var fields = JSObject<JSONValue>()
        fields["clientId"] = .string("summary-child")
        fields["sequenceNumber"] = .number(Double(sequence))
        fields["minimumSequenceNumber"] = .number(0)
        fields["referenceSequenceNumber"] = .number(10)
        fields["clientSequenceNumber"] = .number(1)
        fields["timestamp"] = .number(1000)
        fields["type"] = .string(JSString(type))
        fields["contents"] = try JSON.parse(contents)
        return try ISequencedDocumentMessage(json: .object(fields))
    }
    func testOpsDuringUploadAreScheduledAfterAck() throws {
        let running = RunningSummarizer(sequenceNumber: 0, now: 0)
        try running.begin(now: 0, referenceSequenceNumber: 0)
        XCTAssertNil(running.process(try message("op", 1, "{}"), now: 1))
        running.complete(acknowledged: true)
        XCTAssertEqual(running.runAfterSummary(now: 60001), "maxTime")
        XCTAssertEqual(running.heuristicData.numRuntimeOps, 1)
    }
    func testAckUsesBroadcastSequenceAndNackDoesNotAdvanceBaseline() throws {
        let generator = SummaryGenerator(ackHandle: "a0")
        let contents = try generator.submitted(handle: "p1", referenceSequenceNumber: 10, minimumSequenceNumber: 5)
        XCTAssertEqual(JSON.stringify(contents), #"{"handle":"p1","head":"a0","message":"Summary @10:5","parents":["a0"]}"#)
        XCTAssertFalse(try generator.process(message("summarize", 11, #"{"handle":"p1"}"#)))
        XCTAssertFalse(try generator.process(message("summaryAck", 12, #"{"handle":"wrong","summaryProposal":{"summarySequenceNumber":10}}"#)))
        XCTAssertEqual(generator.ackHandle, "a0")
        XCTAssertFalse(try generator.process(message("summaryNack", 13, #"{"summaryProposal":{"summarySequenceNumber":11},"retryAfter":2}"#)))
        XCTAssertEqual(generator.ackHandle, "a0")
        XCTAssertNil(generator.pendingHandle)
        _ = try generator.submitted(handle: "p2", referenceSequenceNumber: 13, minimumSequenceNumber: 5)
        XCTAssertFalse(try generator.process(message("summarize", 14, #"{"handle":"p2"}"#)))
        XCTAssertTrue(try generator.process(message("summaryAck", 15, #"{"handle":"a2","summaryProposal":{"summarySequenceNumber":14}}"#)))
        XCTAssertEqual(generator.ackHandle, "a2")
        XCTAssertEqual(generator.proposalHandle, "p2")
        XCTAssertEqual(generator.acknowledgedCount, 1)
    }
}
