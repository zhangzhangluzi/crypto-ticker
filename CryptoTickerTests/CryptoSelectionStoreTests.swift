import XCTest
@testable import CryptoTicker

final class CryptoSelectionStoreTests: XCTestCase {
    func testNormalizedSelectionUsesDefaultWhenNothingWasPersisted() {
        let selection = CryptoSelectionStore.normalizedSelection(
            nil,
            defaultSymbols: ["btcusdt"],
            validSymbols: ["btcusdt", "ethusdt"]
        )

        XCTAssertEqual(selection, ["btcusdt"])
    }

    func testNormalizedSelectionDropsInvalidSymbols() {
        let selection = CryptoSelectionStore.normalizedSelection(
            ["ethusdt", "not-a-symbol"],
            defaultSymbols: ["btcusdt"],
            validSymbols: ["btcusdt", "ethusdt"]
        )

        XCTAssertEqual(selection, ["ethusdt"])
    }

    func testNormalizedSelectionFallsBackWhenPersistedSelectionIsEmptyAfterValidation() {
        let selection = CryptoSelectionStore.normalizedSelection(
            [],
            defaultSymbols: ["btcusdt"],
            validSymbols: ["btcusdt", "ethusdt"]
        )

        XCTAssertEqual(selection, ["btcusdt"])
    }

    func testToggleDoesNotRemoveLastSelectedSymbol() {
        let selection = CryptoSelectionStore.toggledSelection("btcusdt", in: ["btcusdt"])

        XCTAssertEqual(selection, ["btcusdt"])
    }

    func testToggleRemovesSelectedSymbolWhenMoreThanOneSymbolRemains() {
        let selection = CryptoSelectionStore.toggledSelection("ethusdt", in: ["btcusdt", "ethusdt"])

        XCTAssertEqual(selection, ["btcusdt"])
    }

    func testToggleAddsUnselectedSymbol() {
        let selection = CryptoSelectionStore.toggledSelection("ethusdt", in: ["btcusdt"])

        XCTAssertEqual(selection, ["btcusdt", "ethusdt"])
    }
}
