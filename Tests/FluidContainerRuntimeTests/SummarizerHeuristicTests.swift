import XCTest
@testable import FluidContainerRuntime

final class SummarizerHeuristicTests: XCTestCase {
    func testStrictThresholdAndAckRetiresOnlyCapturedOps() {
        let data = SummarizeHeuristicData(lastOpSequenceNumber: 1, summaryTime: 0)
        let runner = SummarizeHeuristicRunner(data: data)
        data.numRuntimeOps = 100
        data.lastOpSequenceNumber = 101
        XCTAssertNil(runner.run(now: 60000))
        XCTAssertEqual(runner.idleTime, 0)
        data.numRuntimeOps = 101
        XCTAssertEqual(runner.run(now: 60000), "maxOps")
        XCTAssertEqual(runner.run(now: 60001), "maxTime")
        data.recordAttempt(now: 60001)
        data.numRuntimeOps += 3
        data.markLastAttemptAsSuccessful()
        XCTAssertEqual(data.numRuntimeOps, 3)
        XCTAssertNil(runner.run(now: 120002))
        data.lastOpSequenceNumber += 3
        XCTAssertEqual(runner.run(now: 120002), "maxTime")
    }
}
