import Foundation
import os.log

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

private struct PriceSnapshot {
    let symbol: String
    let price: String
    let change: String
}

@MainActor
class WebSocketManager: ObservableObject {
    @Published var prices: [String: String] = [:]
    @Published var selectedSymbols: [String] = []
    @Published var priceChanges: [String: String] = [:]
    @Published var connectionStates: [String: ConnectionState] = [:]
    @Published private(set) var activeProvider: MarketDataProvider = .binance

    private var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var lastSnapshotUpdatedAt: [String: Date] = [:]
    private var providerRecoveryTask: Task<Void, Never>?
    private var binanceConsecutiveFailures = 0
    private let urlSession = URLSession(configuration: .default)
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "WebSocketManager")

    let availableCurrencies = CryptoCurrency.availableCurrencies

    nonisolated private static let currenciesBySymbol = Dictionary(uniqueKeysWithValues: CryptoCurrency.availableCurrencies.map { ($0.symbol, $0) })
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

    var providerStatusText: String {
        switch activeProvider {
        case .binance:
            return "Source: Binance"
        case .okx:
            return "Source: OKX (fallback)"
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
        let persistedSymbols = UserDefaults.standard.array(forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos) as? [String] ?? AppConfiguration.Defaults.selectedCryptos
        let validSymbols = persistedSymbols.filter { Self.currenciesBySymbol[$0] != nil }
        selectedSymbols = validSymbols.isEmpty ? AppConfiguration.Defaults.selectedCryptos : validSymbols
    }

    private func saveSelectedCryptos() {
        UserDefaults.standard.set(selectedSymbols, forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos)
    }

    func fetchAllCryptoPrices() async {
        logger.info("Fetching prices for all \(self.availableCurrencies.count) cryptocurrencies from \(self.activeProvider.displayName, privacy: .public)")
        await fetchPrices(for: availableCurrencies.map(\.symbol), provider: activeProvider, updateSelectedSymbolsPrices: true)
        logger.info("Completed fetching all cryptocurrency prices")
    }

    func refreshMenuDataIfNeeded() async {
        let now = Date()
        let symbolsToRefresh = availableCurrencies.compactMap { currency -> String? in
            let symbol = currency.symbol

            if prices[symbol] == nil || priceChanges[symbol] == nil {
                return symbol
            }

            guard let lastUpdatedAt = lastSnapshotUpdatedAt[symbol] else {
                return symbol
            }

            let age = now.timeIntervalSince(lastUpdatedAt)
            return age >= AppConfiguration.WebSocket.snapshotRefreshInterval ? symbol : nil
        }

        guard !symbolsToRefresh.isEmpty else { return }

        logger.info("Refreshing \(symbolsToRefresh.count) stale menu snapshots from \(self.activeProvider.displayName, privacy: .public)")
        await fetchPrices(for: symbolsToRefresh, provider: activeProvider, updateSelectedSymbolsPrices: false)
    }

    nonisolated private static func fetchPriceSnapshot(for symbol: String, provider: MarketDataProvider) async throws -> PriceSnapshot {
        switch provider {
        case .binance:
            return try await fetchBinancePriceSnapshot(for: symbol)
        case .okx:
            return try await fetchOKXPriceSnapshot(for: symbol)
        }
    }

    nonisolated private static func fetchBinancePriceSnapshot(for symbol: String) async throws -> PriceSnapshot {
        guard let url = URL(string: "\(AppConfiguration.API.binanceBaseURL)/ticker/24hr?symbol=\(symbol.uppercased())") else {
            throw WebSocketError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WebSocketError.invalidResponse(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let priceStr = json["lastPrice"] as? String,
              let changeStr = json["priceChangePercent"] as? String else {
            throw WebSocketError.dataParsingFailed
        }

        return PriceSnapshot(symbol: symbol, price: priceStr, change: changeStr)
    }

    nonisolated private static func fetchOKXPriceSnapshot(for symbol: String) async throws -> PriceSnapshot {
        guard let currency = currenciesBySymbol[symbol],
              let encodedInstId = currency.okxInstrumentID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(AppConfiguration.API.okxBaseURL)/market/ticker?instId=\(encodedInstId)") else {
            throw WebSocketError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WebSocketError.invalidResponse(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let ticker = dataArray.first,
              let priceStr = ticker["last"] as? String,
              let openStr = ticker["open24h"] as? String,
              let price = Double(priceStr),
              let open = Double(openStr),
              open != 0 else {
            throw WebSocketError.dataParsingFailed
        }

        let change = ((price - open) / open) * 100
        return PriceSnapshot(symbol: symbol, price: priceStr, change: String(change))
    }

    func connectWebSockets() {
        let symbolsToDisconnect = Set(webSocketTasks.keys).subtracting(Set(selectedSymbols))
        for symbol in symbolsToDisconnect {
            disconnectWebSocket(for: symbol)
        }

        for symbol in selectedSymbols where webSocketTasks[symbol] == nil {
            connectWebSocket(for: symbol)
        }
    }

    private func connectWebSocket(for symbol: String) {
        cancelReconnect(for: symbol)

        if let existingTask = webSocketTasks.removeValue(forKey: symbol) {
            existingTask.cancel(with: .goingAway, reason: nil)
        }

        let provider = activeProvider

        guard let url = webSocketURL(for: symbol, provider: provider) else {
            logger.error("Invalid WebSocket URL for symbol: \(symbol)")
            updateConnectionState(for: symbol, state: .error(.invalidURL))
            return
        }

        updateConnectionState(for: symbol, state: .connecting)

        let task = urlSession.webSocketTask(with: url)
        webSocketTasks[symbol] = task

        task.resume()
        subscribeIfNeeded(task, for: symbol, provider: provider)
        receiveMessage(for: symbol, provider: provider)
    }

    private func receiveMessage(for symbol: String, provider: MarketDataProvider) {
        guard let task = webSocketTasks[symbol] else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeProvider == provider else { return }
                guard self.selectedSymbols.contains(symbol) else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleIncomingData(text, for: symbol, provider: provider)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            self.logger.error("Unsupported binary WebSocket message for \(symbol)")
                            self.receiveMessage(for: symbol, provider: provider)
                            return
                        }
                        self.handleIncomingData(text, for: symbol, provider: provider)
                    @unknown default:
                        self.logger.error("Unsupported WebSocket message received for \(symbol)")
                    }

                    if self.webSocketTasks[symbol] != nil {
                        self.receiveMessage(for: symbol, provider: provider)
                    }

                case .failure(let error):
                    self.logger.error("WebSocket error for \(symbol) on \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.webSocketTasks.removeValue(forKey: symbol)
                    self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                    self.recordProviderFailure(provider, context: "WebSocket receive", error: error)
                    self.scheduleReconnect(for: symbol, provider: provider)
                }
            }
        }
    }

    private func handleIncomingData(_ text: String, for symbol: String, provider: MarketDataProvider) {
        switch provider {
        case .binance:
            handleBinanceMessage(text, for: symbol)
        case .okx:
            handleOKXMessage(text, for: symbol)
        }
    }

    private func handleBinanceMessage(_ text: String, for symbol: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let priceStr = json["p"] as? String else {
            logger.error("Failed to parse Binance WebSocket data for \(symbol)")
            return
        }

        recordProviderSuccess(.binance)

        if case .connecting = connectionStates[symbol] {
            updateConnectionState(for: symbol, state: .connected)
        }

        updatePrice(priceStr, for: symbol)
    }

    private func handleOKXMessage(_ text: String, for symbol: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse OKX WebSocket data for \(symbol)")
            return
        }

        if let event = json["event"] as? String {
            if event == "subscribe" {
                recordProviderSuccess(.okx)
                if case .connecting = connectionStates[symbol] {
                    updateConnectionState(for: symbol, state: .connected)
                }
                return
            }

            if event == "error" {
                let statusCode = Int(json["code"] as? String ?? "") ?? -1
                let error = WebSocketError.invalidResponse(statusCode)
                logger.error("OKX WebSocket subscription error for \(symbol): \(String(describing: json), privacy: .public)")
                webSocketTasks.removeValue(forKey: symbol)
                updateConnectionState(for: symbol, state: .error(error))
                recordProviderFailure(.okx, context: "WebSocket subscribe", error: error)
                scheduleReconnect(for: symbol, provider: .okx)
            }
            return
        }

        guard let dataArray = json["data"] as? [[String: Any]],
              let ticker = dataArray.first,
              let priceStr = ticker["last"] as? String else {
            return
        }

        recordProviderSuccess(.okx)

        if case .connecting = connectionStates[symbol] {
            updateConnectionState(for: symbol, state: .connected)
        }

        updatePrice(priceStr, for: symbol)
    }

    private func updatePrice(_ rawPrice: String, for symbol: String) {
        guard selectedSymbols.contains(symbol) else { return }

        let formattedPrice = formatPrice(rawPrice)
        let previousPrice = prices[symbol]
        prices[symbol] = formattedPrice

        guard previousPrice != formattedPrice else { return }

        NotificationCenter.default.post(
            name: .priceUpdated,
            object: nil,
            userInfo: [NotificationUserInfoKey.symbols: [symbol]]
        )
    }

    private func updateConnectionState(for symbol: String, state: ConnectionState) {
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
        let symbols = Array(Set(webSocketTasks.keys).union(reconnectTasks.keys))
        symbols.forEach { disconnectWebSocket(for: $0) }
    }

    private func disconnectWebSocket(for symbol: String) {
        cancelReconnect(for: symbol)

        if let task = webSocketTasks.removeValue(forKey: symbol) {
            task.cancel(with: .goingAway, reason: nil)
        }

        updateConnectionState(for: symbol, state: .disconnected)
    }

    func toggleCryptoSelection(_ symbol: String) {
        if let index = selectedSymbols.firstIndex(of: symbol) {
            selectedSymbols.remove(at: index)
        } else {
            selectedSymbols.append(symbol)
        }
        saveSelectedCryptos()
        connectWebSockets()
        NotificationCenter.default.post(
            name: .selectedSymbolsChanged,
            object: nil,
            userInfo: [NotificationUserInfoKey.symbol: symbol]
        )
    }

    private func formatPrice(_ price: String) -> String {
        guard let priceDouble = Double(price) else { return price }

        let formatter: NumberFormatter = {
            switch priceDouble {
            case 1000...:
                return Self.wholeNumberPriceFormatter
            case 1..<1000:
                return Self.twoDecimalPriceFormatter
            default:
                return Self.fourDecimalPriceFormatter
            }
        }()

        return formatter.string(from: NSNumber(value: priceDouble)) ?? price
    }

    private func formatPercent(_ percent: String) -> String {
        guard let percentDouble = Double(percent) else { return percent }
        return Self.percentFormatter.string(from: NSNumber(value: percentDouble)) ?? percent
    }

    func getCurrency(for symbol: String) -> CryptoCurrency? {
        Self.currenciesBySymbol[symbol]
    }

    func isConnected(for symbol: String) -> Bool {
        if case .connected = connectionStates[symbol] { return true }
        return false
    }

    private func scheduleReconnect(for symbol: String, provider: MarketDataProvider) {
        cancelReconnect(for: symbol)

        guard selectedSymbols.contains(symbol) else { return }

        reconnectTasks[symbol] = Task { [weak self] in
            let delay = UInt64(AppConfiguration.WebSocket.reconnectDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self = self else { return }

                self.reconnectTasks.removeValue(forKey: symbol)

                guard self.activeProvider == provider else { return }
                guard self.selectedSymbols.contains(symbol) else { return }
                self.connectWebSocket(for: symbol)
            }
        }
    }

    private func cancelReconnect(for symbol: String) {
        reconnectTasks[symbol]?.cancel()
        reconnectTasks.removeValue(forKey: symbol)
    }

    private func fetchPrices(for symbols: [String], provider: MarketDataProvider, updateSelectedSymbolsPrices: Bool) async {
        guard !symbols.isEmpty else { return }

        var snapshots: [PriceSnapshot] = []

        await withTaskGroup(of: Result<PriceSnapshot, Error>.self) { group in
            for symbol in symbols {
                group.addTask {
                    do {
                        return .success(try await Self.fetchPriceSnapshot(for: symbol, provider: provider))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let snapshot):
                    snapshots.append(snapshot)
                case .failure(let error):
                    logger.error("Failed to fetch a cryptocurrency price from \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard activeProvider == provider else { return }

        if snapshots.isEmpty {
            recordProviderFailure(provider, context: "Snapshot refresh", error: WebSocketError.dataParsingFailed)
            return
        }

        recordProviderSuccess(provider)

        var changedSymbols: [String] = []
        let now = Date()

        for snapshot in snapshots {
            lastSnapshotUpdatedAt[snapshot.symbol] = now

            let formattedPrice = formatPrice(snapshot.price)
            let formattedChange = formatPercent(snapshot.change) + "%"
            var didChangeSymbol = false

            let shouldUpdateDisplayedPrice = updateSelectedSymbolsPrices || !selectedSymbols.contains(snapshot.symbol) || prices[snapshot.symbol] == nil

            if shouldUpdateDisplayedPrice, prices[snapshot.symbol] != formattedPrice {
                prices[snapshot.symbol] = formattedPrice
                didChangeSymbol = true
            }

            if priceChanges[snapshot.symbol] != formattedChange {
                priceChanges[snapshot.symbol] = formattedChange
                didChangeSymbol = true
            }

            if didChangeSymbol {
                changedSymbols.append(snapshot.symbol)
            }
        }

        guard !changedSymbols.isEmpty else { return }
        NotificationCenter.default.post(
            name: .priceUpdated,
            object: nil,
            userInfo: [NotificationUserInfoKey.symbols: changedSymbols]
        )
    }

    private func recordProviderSuccess(_ provider: MarketDataProvider) {
        guard provider == .binance else { return }

        if binanceConsecutiveFailures != 0 {
            logger.info("Binance recovered after \(self.binanceConsecutiveFailures) consecutive failures")
        }
        binanceConsecutiveFailures = 0
    }

    private func recordProviderFailure(_ provider: MarketDataProvider, context: String, error: Error) {
        guard provider == .binance, activeProvider == .binance else { return }

        binanceConsecutiveFailures += 1
        logger.error("Binance failure #\(self.binanceConsecutiveFailures) during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")

        guard binanceConsecutiveFailures >= AppConfiguration.ProviderFallback.binanceFailureThreshold else { return }
        switchProvider(to: .okx, reason: "Binance failed \(binanceConsecutiveFailures) times in a row")
    }

    private func switchProvider(to provider: MarketDataProvider, reason: String) {
        guard activeProvider != provider else { return }

        logger.notice("Switching provider from \(self.activeProvider.displayName, privacy: .public) to \(provider.displayName, privacy: .public): \(reason, privacy: .public)")

        let symbols = Array(Set(webSocketTasks.keys).union(reconnectTasks.keys).union(selectedSymbols))
        symbols.forEach { symbol in
            cancelReconnect(for: symbol)

            if let task = webSocketTasks.removeValue(forKey: symbol) {
                task.cancel(with: .goingAway, reason: nil)
            }

            updateConnectionState(for: symbol, state: .disconnected)
        }

        activeProvider = provider

        NotificationCenter.default.post(
            name: .providerChanged,
            object: nil,
            userInfo: [NotificationUserInfoKey.provider: provider.rawValue]
        )

        connectWebSockets()
        Task { await fetchAllCryptoPrices() }
    }

    private func startProviderRecoveryMonitor() {
        providerRecoveryTask?.cancel()
        providerRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = UInt64(AppConfiguration.ProviderFallback.binanceRecoveryCheckInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)

                guard !Task.isCancelled else { return }
                await self?.probeBinanceRecoveryIfNeeded()
            }
        }
    }

    private func probeBinanceRecoveryIfNeeded() async {
        guard activeProvider != .binance else { return }

        let probeSymbol = selectedSymbols.first ?? AppConfiguration.Defaults.selectedCryptos.first ?? "btcusdt"

        do {
            _ = try await Self.fetchPriceSnapshot(for: probeSymbol, provider: .binance)
            binanceConsecutiveFailures = 0
            switchProvider(to: .binance, reason: "Hourly recovery check succeeded")
        } catch {
            logger.error("Binance hourly recovery check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func webSocketURL(for symbol: String, provider: MarketDataProvider) -> URL? {
        switch provider {
        case .binance:
            return URL(string: "\(AppConfiguration.API.binanceWebSocketURL)/\(symbol)@trade")
        case .okx:
            return URL(string: AppConfiguration.API.okxWebSocketURL)
        }
    }

    private func subscribeIfNeeded(_ task: URLSessionWebSocketTask, for symbol: String, provider: MarketDataProvider) {
        guard provider == .okx,
              let currency = Self.currenciesBySymbol[symbol] else {
            return
        }

        let message = """
        {"op":"subscribe","args":[{"channel":"tickers","instId":"\(currency.okxInstrumentID)"}]}
        """

        task.send(.string(message)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeProvider == provider else { return }

                if let error {
                    self.logger.error("Failed to subscribe to OKX ticker for \(symbol): \(error.localizedDescription, privacy: .public)")
                    self.webSocketTasks.removeValue(forKey: symbol)
                    self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                    self.recordProviderFailure(provider, context: "WebSocket subscribe", error: error)
                    self.scheduleReconnect(for: symbol, provider: provider)
                }
            }
        }
    }

    nonisolated private static func makeDecimalFormatter(maximumFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }
}
