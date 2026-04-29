import XCTest
@testable import CryptoTicker

final class SnapshotFailureEvaluatorTests: XCTestCase {
    func testIgnoresPartialFailureForNonSelectedSymbols() {
        let failure = SnapshotFailureEvaluator.providerHealthFailure(
            from: [
                SnapshotFetchFailure(symbol: "dogeusdt", underlyingError: URLError(.badServerResponse))
            ],
            requestedSymbols: ["btcusdt", "dogeusdt"],
            selectedSymbols: ["btcusdt"]
        )

        XCTAssertNil(failure)
    }

    func testCountsPartialFailureForSelectedSymbols() {
        let failure = SnapshotFailureEvaluator.providerHealthFailure(
            from: [
                SnapshotFetchFailure(symbol: "btcusdt", underlyingError: URLError(.timedOut))
            ],
            requestedSymbols: ["btcusdt", "dogeusdt"],
            selectedSymbols: ["btcusdt"]
        )

        XCTAssertEqual(failure?.context, "Snapshot refresh selected symbol btcusdt failed (1/2 failed)")
    }

    func testCountsProviderFailureWhenAllRequestedSymbolsFail() {
        let failure = SnapshotFailureEvaluator.providerHealthFailure(
            from: [
                SnapshotFetchFailure(symbol: "btcusdt", underlyingError: URLError(.timedOut)),
                SnapshotFetchFailure(symbol: "ethusdt", underlyingError: URLError(.timedOut))
            ],
            requestedSymbols: ["btcusdt", "ethusdt"],
            selectedSymbols: ["dogeusdt"]
        )

        XCTAssertEqual(failure?.context, "Snapshot refresh")
    }
}
