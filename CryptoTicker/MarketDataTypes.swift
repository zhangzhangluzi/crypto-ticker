import Foundation

enum WebSocketError: Error {
    case invalidURL
    case dataParsingFailed
    case invalidResponse(Int)
    case networkError(Error)
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error(WebSocketError)
}

enum MarketDataProvider: String {
    case binance
    case okx

    var displayName: String {
        switch self {
        case .binance:
            return "Binance"
        case .okx:
            return "OKX"
        }
    }
}

struct CryptoCurrency {
    let code: String
    let name: String
    let symbol: String
    let icon: String

    var okxInstrumentID: String {
        "\(code)-USDT"
    }

    static let availableCurrencies = [
        CryptoCurrency(code: "BTC", name: "Bitcoin", symbol: "btcusdt", icon: "₿"),
        CryptoCurrency(code: "ETH", name: "Ethereum", symbol: "ethusdt", icon: "Ξ"),
        CryptoCurrency(code: "XRP", name: "XRP", symbol: "xrpusdt", icon: "✕"),
        CryptoCurrency(code: "BNB", name: "BNB", symbol: "bnbusdt", icon: "B"),
        CryptoCurrency(code: "SOL", name: "Solana", symbol: "solusdt", icon: "S"),
        CryptoCurrency(code: "DOGE", name: "Dogecoin", symbol: "dogeusdt", icon: "Ɖ"),
        CryptoCurrency(code: "TRX", name: "TRON", symbol: "trxusdt", icon: "T")
    ]
}

struct PriceSnapshot {
    let symbol: String
    let price: String
    let change: String
}

struct SnapshotFetchFailure: Error {
    let symbol: String
    let underlyingError: Error
}

enum SnapshotFailurePolicy {
    case updateProviderHealth
    case ignoreProviderHealth
}

struct ProviderHealthFailure {
    let context: String
    let error: Error
}
