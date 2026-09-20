@testable import ForgeOpsTracker
import XCTest

final class HistogramBucketerTests: XCTestCase {
    func testReturnsTheSmallestBoundaryADurationFitsUnderAsAString() {
        XCTAssertEqual(HistogramBucketer.bucketFor(10), "50")
        XCTAssertEqual(HistogramBucketer.bucketFor(50), "50")
        XCTAssertEqual(HistogramBucketer.bucketFor(50.5), "100")
        XCTAssertEqual(HistogramBucketer.bucketFor(4999), "5000")
    }

    func testReturnsInfForAnythingLargerThanTheLargestBoundary() {
        XCTAssertEqual(HistogramBucketer.bucketFor(10_001), "inf")
        XCTAssertEqual(HistogramBucketer.bucketFor(1_000_000), "inf")
    }

    func testPutsADurationExactlyOnABoundaryIntoThatBoundarysOwnBucket() {
        for boundary in HistogramBucketer.boundariesMs {
            XCTAssertEqual(HistogramBucketer.bucketFor(boundary), String(Int(boundary)))
        }
    }

    func testBoundariesMatchTheServersHistogramPercentile() {
        // app/services/histogram_percentile.rb and every other SDK must agree on this exact list.
        XCTAssertEqual(HistogramBucketer.boundariesMs, [50, 100, 250, 500, 1000, 2500, 5000, 10_000])
    }
}
