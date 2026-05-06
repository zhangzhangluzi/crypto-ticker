import Foundation
import os.log

@MainActor
class WebSocketManager: ObservableObject {
    @Published var prices: [String: String] = [:]
    @Published var selectedSymbols: [String] = []
    @Published var priceChanges: [String: String] = [:]
    @Published var connectionStates: [String: ConnectionState] = [:]
    @Published var activeProvider: MarketDataProvider = .binance

    var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    var reconnectTasks: [String: Task<Void, Never>] = [:]
    var connectionTimeoutTasks: [String: Task<Void, Never>] = [:]
    var staleDataTimeoutTasks: [String: Task<Void, Never>] = [:]
    var okxWebSocketTask: URLSessionWebSocketTask?
    var okxReconnectTask: Task<Void, Never>?
    var okxConnectionTimeoutTasks: [String: Task<Void, Never>] = [:]
    var okxSubscribedSymbols: Set<String> = []
    var lastSnapshotUpdatedAt: [String: Date] = [:]
    var lastWebSocketMessageAt: [String: Date] = [:]
    var providerFailureCountsBySymbol: [MarketDataProvider: [String: Int]] = [:]
    var providerRecoveryTask: Task<Void, Never>?
    var binanceConsecutiveFailures = 0
    var okxConsecutiveFailures = 0
    var isOKXUnavailable = false
    let urlSession = URLSession(configuration: .default)
    let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "WebSocketManager")

    let availableCurrencies = CryptoCurrency.availableCurrencies

    nonisolated static let currenciesBySymbol = Dictionary(uniqueKeysWithValues: CryptoCurrency.availableCurrencies.map { ($0.symbol, $0) })
    nonisolated static let symbolsByOKXInstrumentID = Dictionary(uniqueKeysWithValues: CryptoCurrency.availableCurrencies.map { ($0.okxInstrumentID, $0.symbol) })

    var providerStatusText: String {
        switch activeProvider {
        case .binance:
            return "Source: Binance"
        case .okx:
            return isOKXUnavailable ? "Source: OKX (fallback unavailable)" : "Source: OKX (fallback)"
        }
    }

    var isUsingFallbackProvider: Bool {
        activeProvider != .binance
    }

    init() {
        loadSelectedCryptos()
        connectWebSockets()
        startProviderRecoveryMonitor()
        Task { await fetchAllCryptoPrices() }
    }

    private func loadSelectedCryptos() {
        selectedSymbols = CryptoSelectionStore.load()
    }

    private func saveSelectedCryptos() {
        CryptoSelectionStore.save(selectedSymbols)
    }

    func updatePrice(_ rawPrice: String, for symbol: String) {
        guard selectedSymbols.contains(symbol) else { return }

        let formattedPrice = MarketDataFormatter.formatPrice(rawPrice)
        let previousPrice = prices[symbol]
        prices[symbol] = formattedPrice

        guard previousPrice != formattedPrice else { return }

        NotificationCenter.default.post(
            name: .priceUpdated,
            object: nil,
            userInfo: [NotificationUserInfoKey.symbols: [symbol]]
        )
    }

    func updateConnectionState(for symbol: String, state: ConnectionState) {
        connectionStates[symbol] = state
        NotificationCenter.default.post(
            name: .connectionStateChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.symbol: symbol,
                NotificationUserInfoKey.state: state
            ]
        )
    }

    func disconnectWebSockets() {
        logger.info("Disconnecting all WebSockets")
        providerRecoveryTask?.cancel()
        providerRecoveryTask = nil
        cancelAllConnectionTimeouts()
        disconnectAllBinanceWebSockets()
        disconnectOKXWebSocket(resetConnectionStates: true)
    }

    func toggleCryptoSelection(_ symbol: String) {
        let nextSymbols = CryptoSelectionStore.toggledSelection(symbol, in: selectedSymbols)
        guard nextSymbols != selectedSymbols else {
            logger.info("Ignoring request to deselect the last cryptocurrency")
            return
        }

        selectedSymbols = nextSymbols
        saveSelectedCryptos()
        connectWebSockets()
        NotificationCenter.default.post(
            name: .selectedSymbolsChanged,
            object: nil,
            userInfo: [NotificationUserInfoKey.symbol: symbol]
        )
    }

    func getCurrency(for symbol: String) -> CryptoCurrency? {
        Self.currenciesBySymbol[symbol]
    }

    func isConnected(for symbol: String) -> Bool {
        if case .connected = connectionStates[symbol] { return true }
        return false
    }
}
