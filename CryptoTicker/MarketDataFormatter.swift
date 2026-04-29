import Foundation

enum MarketDataFormatter {
    private static let wholeNumberPriceFormatter = makeDecimalFormatter(maximumFractionDigits: 0)
    private static let twoDecimalPriceFormatter = makeDecimalFormatter(maximumFractionDigits: 2)
    private static let fourDecimalPriceFormatter = makeDecimalFormatter(maximumFractionDigits: 4)
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        return formatter
    }()

    static func formatPrice(_ price: String) -> String {
        guard let priceDouble = Double(price) else { return price }

        let formatter: NumberFormatter = {
            switch priceDouble {
            case 1000...:
                return wholeNumberPriceFormatter
            case 1..<1000:
                return twoDecimalPriceFormatter
            default:
                return fourDecimalPriceFormatter
            }
        }()

        return formatter.string(from: NSNumber(value: priceDouble)) ?? price
    }

    static func formatPercent(_ percent: String) -> String {
        guard let percentDouble = Double(percent) else { return percent }
        return percentFormatter.string(from: NSNumber(value: percentDouble)) ?? percent
    }

    private static func makeDecimalFormatter(maximumFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }
}
