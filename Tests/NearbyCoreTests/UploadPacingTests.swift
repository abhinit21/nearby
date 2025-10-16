import XCTest
@testable import NearbyCore

final class UploadPacingTests: XCTestCase {
    func testInitialBurstThenSustainedBudgetDoesNotReserveDuringWait() {
        var bucket = UploadTokenBucket(bytesPerSecond: 65_536)
        XCTAssertEqual(bucket.consume(65_536, at: 0), 0)
        XCTAssertEqual(bucket.consume(8_192, at: 0), 0.125, accuracy: 0.000_001)
        XCTAssertEqual(bucket.consume(8_192, at: 0), 0.125, accuracy: 0.000_001)
        XCTAssertEqual(bucket.consume(8_192, at: 0.0625), 0.0625, accuracy: 0.000_001)
        XCTAssertEqual(bucket.consume(8_192, at: 0.125), 0)
        XCTAssertEqual(bucket.consume(8_192, at: 0.125), 0.125, accuracy: 0.000_001)
    }

    func testIdleTimeCannotAccumulateMoreThanOneSyncDataChunk() {
        var bucket = UploadTokenBucket(bytesPerSecond: 65_536)
        XCTAssertEqual(bucket.consume(65_536, at: 0), 0)
        XCTAssertEqual(bucket.consume(65_536, at: 100), 0)
        XCTAssertEqual(bucket.consume(65_536, at: 100), 1)
        XCTAssertEqual(bucket.burstBytes, 65_536)
    }

    func testRateChangeCreditsElapsedTimeAtPreviousRateAndPreservesBudget() {
        var bucket = UploadTokenBucket(bytesPerSecond: 65_536)
        XCTAssertEqual(bucket.consume(65_536, at: 0), 0)
        bucket.setRateLimit(bytesPerSecond: 32_768, at: 0.5)
        XCTAssertEqual(bucket.consume(65_536, at: 0.5), 1)
        XCTAssertEqual(bucket.consume(65_536, at: 1.5), 0)
        XCTAssertEqual(bucket.consume(65_536, at: 1.5), 2)
    }

    func testUnlimitedAndInvalidRatesHaveExplicitBehavior() {
        var bucket = UploadTokenBucket(bytesPerSecond: nil)
        for _ in 0..<10 { XCTAssertEqual(bucket.consume(65_536, at: 0), 0) }
        bucket.setRateLimit(bytesPerSecond: 0, at: 0)
        XCTAssertEqual(bucket.bytesPerSecond, 1)
        XCTAssertEqual(bucket.consume(65_536, at: 0), 0)
        XCTAssertEqual(bucket.consume(1, at: 0), 1)
        bucket.setRateLimit(bytesPerSecond: nil, at: 0)
        XCTAssertNil(bucket.bytesPerSecond)
        XCTAssertEqual(bucket.consume(65_536, at: 0), 0)
    }

    func testClockRegressionDoesNotCreateCredit() {
        var bucket = UploadTokenBucket(bytesPerSecond: 65_536)
        XCTAssertEqual(bucket.consume(65_536, at: 10), 0)
        XCTAssertEqual(bucket.consume(65_536, at: 9), 1)
        XCTAssertEqual(bucket.consume(65_536, at: 10), 1)
        XCTAssertEqual(bucket.consume(65_536, at: 11), 0)
    }
}
