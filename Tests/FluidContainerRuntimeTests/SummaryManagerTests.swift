import XCTest
@testable import FluidContainerRuntime

final class SummaryManagerTests: XCTestCase {
    func testThrottlingCompensatesForDelayAndExpiresWindow() {
        let throttler = Throttler()
        XCTAssertEqual(throttler.getDelay(now: 0), 0)
        XCTAssertEqual(throttler.getDelay(now: 1), 40)
        XCTAssertEqual(throttler.getDelay(now: 2), 80)
        XCTAssertEqual(throttler.getDelay(now: 70000), 0)
        XCTAssertEqual(throttler.numAttempts, 1)
    }
}
