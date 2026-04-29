import XCTest
@testable import CryptoTicker

final class MarketDataFormatterTests: XCTestCase {
    func testFormatsLargePricesWithoutFractionDigits() {
        XCTAssertEqual(MarketDataFormatter.formatPrice("12345.678"), "12,346")
    }

    func testFormatsMidRangePricesWithTwoFractionDigits() {
        XCTAssertEqual(MarketDataFormatter.formatPrice("123.4567"), "123.46")
    }

    func testFormatsSmallPricesWithFourFractionDigits() {
        XCTAssertEqual(MarketDataFormatter.formatPrice("0.123456"), "0.1235")
    }

    func testFormatsPositivePercentWithSign() {
        XCTAssertEqual(MarketDataFormatter.formatPercent("1.234"), "+1.23")
    }
}
