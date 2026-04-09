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

private struct SnapshotFetchFailure: Error {
    let symbol: String
    let underlyingError: Error
}

private enum SnapshotFailurePolicy {
    case updateProviderHealth
    case ignoreProviderHealth
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
    private var okxWebSocketTask: URLSessionWebSocketTask?
    private var okxReconnectTask: Task<Void, Never>?
    private var okxSubscribedSymbols: Set<String> = []
    private var lastSnapshotUpdatedAt: [String: Date] = [:]
    private var providerRecoveryTask: Task<Void, Never>?
    private var binanceConsecutiveFailures = 0
    private var okxConsecutiveFailures = 0
    private var isOKXUnavailable = false
    private let urlSession = URLSession(configuration: .default)
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "WebSocketManager")

    let availableCurrencies = CryptoCurrency.availableCurrencies

    nonisolated private static let currenciesBySymbol = Dictionary(uniqueKeysWithValues: CryptoCurrency.availableCurrencies.map { ($0.symbol, $0) })
    nonisolated private static let symbolsByOKXInstrumentID = Dictionary(uniqueKeysWithValues: CryptoCurrency.availableCurrencies.map { ($0.okxInstrumentID, $0.symbol) })
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
        let persistedSymbols = UserDefaults.standard.array(forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos) as? [String] ?? AppConfiguration.Defaults.selectedCryptos
        let validSymbols = persistedSymbols.filter { Self.currenciesBySymbol[$0] != nil }
        selectedSymbols = validSymbols.isEmpty ? AppConfiguration.Defaults.selectedCryptos : validSymbols
    }

    private func saveSelectedCryptos() {
        UserDefaults.standard.set(selectedSymbols, forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos)
    }

    func fetchAllCryptoPrices() async {
        logger.info("Fetching prices for all \(self.availableCurrencies.count) cryptocurrencies from \(self.activeProvider.displayName, privacy: .public)")
        await fetchPrices(
            for: availableCurrencies.map(\.symbol),
            provider: activeProvider,
            failurePolicy: .updateProviderHealth
        )
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
        await fetchPrices(
            for: symbolsToRefresh,
            provider: activeProvider,
            failurePolicy: .ignoreProviderHealth
        )
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

    nonisolated private static func probeBinanceRealtimeFeed(for symbol: String) async throws {
        guard let url = URL(string: "\(AppConfiguration.API.binanceWebSocketURL)/\(symbol)@trade") else {
            throw WebSocketError.invalidURL
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let timeoutInNanoseconds = UInt64(AppConfiguration.ProviderFallback.binanceRecoveryWebSocketTimeout * 1_000_000_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let message = try await task.receive()
                try validateBinanceTradeMessage(message)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutInNanoseconds)
                throw WebSocketError.networkError(URLError(.timedOut))
            }

            _ = try await group.next()
            group.cancelAll()
        }
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
        switch activeProvider {
        case .binance:
            disconnectOKXWebSocket(resetConnectionStates: false)
            syncBinanceWebSockets()
        case .okx:
            disconnectAllBinanceWebSockets()
            syncOKXWebSocket()
        }
    }

    private func syncBinanceWebSockets() {
        let symbolsToDisconnect = Set(webSocketTasks.keys).subtracting(Set(selectedSymbols))
        for symbol in symbolsToDisconnect {
            disconnectWebSocket(for: symbol)
        }

        for symbol in selectedSymbols where webSocketTasks[symbol] == nil {
            connectWebSocket(for: symbol)
        }
    }

    private func syncOKXWebSocket() {
        let desiredSymbols = Set(selectedSymbols)

        guard !desiredSymbols.isEmpty else {
            disconnectOKXWebSocket(resetConnectionStates: true)
            return
        }

        guard let task = okxWebSocketTask else {
            connectOKXWebSocket(for: desiredSymbols)
            return
        }

        let removedSymbols = okxSubscribedSymbols.subtracting(desiredSymbols)
        let addedSymbols = desiredSymbols.subtracting(okxSubscribedSymbols)

        guard !removedSymbols.isEmpty || !addedSymbols.isEmpty else {
            return
        }

        for symbol in removedSymbols {
            updateConnectionState(for: symbol, state: .disconnected)
        }

        if !removedSymbols.isEmpty {
            okxSubscribedSymbols.subtract(removedSymbols)
            unsubscribeFromOKXTickers(task, symbols: removedSymbols)
        }

        if !addedSymbols.isEmpty {
            okxSubscribedSymbols.formUnion(addedSymbols)
            for symbol in addedSymbols {
                updateConnectionState(for: symbol, state: .connecting)
            }
            subscribeToOKXTickers(task, symbols: addedSymbols)
        }
    }

    private func connectWebSocket(for symbol: String) {
        cancelReconnect(for: symbol)

        if let existingTask = webSocketTasks.removeValue(forKey: symbol) {
            existingTask.cancel(with: .goingAway, reason: nil)
        }

        guard let url = webSocketURL(for: symbol, provider: .binance) else {
            logger.error("Invalid WebSocket URL for symbol: \(symbol)")
            updateConnectionState(for: symbol, state: .error(.invalidURL))
            return
        }

        updateConnectionState(for: symbol, state: .connecting)

        let task = urlSession.webSocketTask(with: url)
        webSocketTasks[symbol] = task

        task.resume()
        receiveMessage(for: symbol)
    }

    private func connectOKXWebSocket(for symbols: Set<String>) {
        cancelOKXReconnect()

        if let existingTask = okxWebSocketTask {
            existingTask.cancel(with: .goingAway, reason: nil)
        }

        okxSubscribedSymbols = symbols

        guard let url = webSocketURL(for: nil, provider: .okx) else {
            logger.error("Invalid OKX WebSocket URL")
            for symbol in symbols {
                updateConnectionState(for: symbol, state: .error(.invalidURL))
            }
            return
        }

        for symbol in symbols {
            updateConnectionState(for: symbol, state: .connecting)
        }

        let task = urlSession.webSocketTask(with: url)
        okxWebSocketTask = task
        task.resume()
        subscribeToOKXTickers(task, symbols: symbols)
        receiveOKXMessages(task)
    }

    private func receiveMessage(for symbol: String) {
        guard let task = webSocketTasks[symbol] else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeProvider == .binance else { return }
                guard self.selectedSymbols.contains(symbol) else { return }
                guard self.webSocketTasks[symbol] === task else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleBinanceMessage(text, for: symbol)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            self.logger.error("Unsupported binary WebSocket message for \(symbol)")
                            self.receiveMessage(for: symbol)
                            return
                        }
                        self.handleBinanceMessage(text, for: symbol)
                    @unknown default:
                        self.logger.error("Unsupported WebSocket message received for \(symbol)")
                    }

                    if self.webSocketTasks[symbol] != nil {
                        self.receiveMessage(for: symbol)
                    }

                case .failure(let error):
                    self.logger.error("WebSocket error for \(symbol) on Binance: \(error.localizedDescription, privacy: .public)")
                    self.webSocketTasks.removeValue(forKey: symbol)
                    self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                    self.recordProviderFailure(.binance, context: "WebSocket receive", error: error)
                    self.scheduleReconnect(for: symbol, provider: .binance)
                }
            }
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

    private func receiveOKXMessages(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeProvider == .okx else { return }
                guard self.okxWebSocketTask === task else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleOKXMessage(text)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            self.logger.error("Unsupported binary OKX WebSocket message")
                            self.receiveOKXMessages(task)
                            return
                        }
                        self.handleOKXMessage(text)
                    @unknown default:
                        self.logger.error("Unsupported OKX WebSocket message received")
                    }

                    if self.okxWebSocketTask === task {
                        self.receiveOKXMessages(task)
                    }

                case .failure(let error):
                    self.logger.error("OKX WebSocket error: \(error.localizedDescription, privacy: .public)")
                    self.okxWebSocketTask = nil
                    for symbol in self.okxSubscribedSymbols {
                        self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                    }
                    self.recordProviderFailure(.okx, context: "WebSocket receive", error: error)
                    self.scheduleReconnect(provider: .okx)
                }
            }
        }
    }

    private func handleOKXMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse OKX WebSocket data")
            return
        }

        if let event = json["event"] as? String {
            if event == "subscribe" {
                recordProviderSuccess(.okx)

                if let arg = json["arg"] as? [String: Any],
                   let instId = arg["instId"] as? String,
                   let symbol = Self.symbolsByOKXInstrumentID[instId],
                   case .connecting = connectionStates[symbol] {
                    updateConnectionState(for: symbol, state: .connected)
                }
                return
            }

            if event == "error" {
                let statusCode = Int(json["code"] as? String ?? "") ?? -1
                let error = WebSocketError.invalidResponse(statusCode)
                logger.error("OKX WebSocket subscription error: \(String(describing: json), privacy: .public)")
                okxWebSocketTask = nil
                let affectedSymbols = okxSymbols(from: json).isEmpty ? okxSubscribedSymbols : okxSymbols(from: json)
                for symbol in affectedSymbols {
                    updateConnectionState(for: symbol, state: .error(error))
                }
                recordProviderFailure(.okx, context: "WebSocket subscribe", error: error)
                scheduleReconnect(provider: .okx)
            }
            return
        }

        guard let dataArray = json["data"] as? [[String: Any]], !dataArray.isEmpty else {
            return
        }

        recordProviderSuccess(.okx)

        for ticker in dataArray {
            guard let instId = ticker["instId"] as? String,
                  let symbol = Self.symbolsByOKXInstrumentID[instId],
                  let priceStr = ticker["last"] as? String else {
                continue
            }

            if case .connecting = connectionStates[symbol] {
                updateConnectionState(for: symbol, state: .connected)
            }

            updatePrice(priceStr, for: symbol)
        }
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
        disconnectAllBinanceWebSockets()
        disconnectOKXWebSocket(resetConnectionStates: true)
    }

    private func disconnectAllBinanceWebSockets() {
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

    private func disconnectOKXWebSocket(resetConnectionStates: Bool) {
        cancelOKXReconnect()

        if let task = okxWebSocketTask {
            task.cancel(with: .goingAway, reason: nil)
            okxWebSocketTask = nil
        }

        let symbols = okxSubscribedSymbols
        okxSubscribedSymbols.removeAll()

        guard resetConnectionStates else { return }

        for symbol in symbols {
            updateConnectionState(for: symbol, state: .disconnected)
        }
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

    private func scheduleReconnect(for symbol: String? = nil, provider: MarketDataProvider) {
        switch provider {
        case .binance:
            guard let symbol else { return }
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
        case .okx:
            cancelOKXReconnect()

            guard !selectedSymbols.isEmpty else { return }

            okxReconnectTask = Task { [weak self] in
                let delay = UInt64(AppConfiguration.WebSocket.reconnectDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self = self else { return }

                    self.okxReconnectTask = nil

                    guard self.activeProvider == .okx else { return }
                    self.syncOKXWebSocket()
                }
            }
        }
    }

    private func cancelOKXReconnect() {
        okxReconnectTask?.cancel()
        okxReconnectTask = nil
    }

    private func cancelReconnect(for symbol: String) {
        reconnectTasks[symbol]?.cancel()
        reconnectTasks.removeValue(forKey: symbol)
    }

    private func fetchPrices(
        for symbols: [String],
        provider: MarketDataProvider,
        failurePolicy: SnapshotFailurePolicy
    ) async {
        guard !symbols.isEmpty else { return }

        var snapshots: [PriceSnapshot] = []
        var failures: [SnapshotFetchFailure] = []

        await withTaskGroup(of: Result<PriceSnapshot, SnapshotFetchFailure>.self) { group in
            for symbol in symbols {
                group.addTask {
                    do {
                        return .success(try await Self.fetchPriceSnapshot(for: symbol, provider: provider))
                    } catch {
                        return .failure(SnapshotFetchFailure(symbol: symbol, underlyingError: error))
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let snapshot):
                    snapshots.append(snapshot)
                case .failure(let failure):
                    failures.append(failure)
                    logger.error("Failed to fetch \(failure.symbol, privacy: .public) from \(provider.displayName, privacy: .public): \(failure.underlyingError.localizedDescription, privacy: .public)")
                }
            }
        }

        guard activeProvider == provider else { return }

        if failurePolicy == .updateProviderHealth, let firstFailure = failures.first {
            let context = failures.count == symbols.count
                ? "Snapshot refresh"
                : "Snapshot refresh partial (\(failures.count)/\(symbols.count) failed)"
            recordProviderFailure(provider, context: context, error: firstFailure.underlyingError)

            guard activeProvider == provider else { return }
        }

        guard !snapshots.isEmpty else { return }

        if failurePolicy == .updateProviderHealth, failures.isEmpty {
            recordProviderSuccess(provider)
        }

        var changedSymbols: [String] = []
        let now = Date()

        for snapshot in snapshots {
            lastSnapshotUpdatedAt[snapshot.symbol] = now

            let formattedPrice = formatPrice(snapshot.price)
            let formattedChange = formatPercent(snapshot.change) + "%"
            var didChangeSymbol = false

            if prices[snapshot.symbol] != formattedPrice {
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
        switch provider {
        case .binance:
            if binanceConsecutiveFailures != 0 {
                logger.info("Binance recovered after \(self.binanceConsecutiveFailures) consecutive failures")
            }
            binanceConsecutiveFailures = 0
        case .okx:
            if okxConsecutiveFailures != 0 {
                logger.info("OKX recovered after \(self.okxConsecutiveFailures) consecutive failures")
            }
            okxConsecutiveFailures = 0
            setOKXUnavailable(false)
        }
    }

    private func recordProviderFailure(_ provider: MarketDataProvider, context: String, error: Error) {
        switch provider {
        case .binance:
            guard activeProvider == .binance else { return }

            binanceConsecutiveFailures += 1
            logger.error("Binance failure #\(self.binanceConsecutiveFailures) during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")

            guard binanceConsecutiveFailures >= AppConfiguration.ProviderFallback.binanceFailureThreshold else { return }
            switchProvider(to: .okx, reason: "Binance failed \(binanceConsecutiveFailures) times in a row")

        case .okx:
            guard activeProvider == .okx else { return }

            okxConsecutiveFailures += 1
            logger.error("OKX failure #\(self.okxConsecutiveFailures) during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")

            guard okxConsecutiveFailures >= AppConfiguration.ProviderFallback.okxFailureThreshold else { return }

            if !isOKXUnavailable {
                logger.notice("OKX fallback became unavailable after \(self.okxConsecutiveFailures) consecutive failures")
                setOKXUnavailable(true)
            }

            for symbol in selectedSymbols {
                updateConnectionState(for: symbol, state: .error(.networkError(error)))
            }
        }
    }

    private func switchProvider(to provider: MarketDataProvider, reason: String) {
        guard activeProvider != provider else { return }

        logger.notice("Switching provider from \(self.activeProvider.displayName, privacy: .public) to \(provider.displayName, privacy: .public): \(reason, privacy: .public)")

        disconnectAllBinanceWebSockets()
        disconnectOKXWebSocket(resetConnectionStates: true)

        okxConsecutiveFailures = 0
        setOKXUnavailable(false)
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
            _ = try await Self.fetchBinancePriceSnapshot(for: probeSymbol)
            try await Self.probeBinanceRealtimeFeed(for: probeSymbol)
            binanceConsecutiveFailures = 0
            switchProvider(to: .binance, reason: "Hourly recovery check succeeded")
        } catch {
            logger.error("Binance hourly recovery check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setOKXUnavailable(_ unavailable: Bool) {
        guard isOKXUnavailable != unavailable else { return }
        isOKXUnavailable = unavailable

        guard activeProvider == .okx else { return }

        NotificationCenter.default.post(
            name: .providerChanged,
            object: nil,
            userInfo: [NotificationUserInfoKey.provider: activeProvider.rawValue]
        )
    }

    private func webSocketURL(for symbol: String?, provider: MarketDataProvider) -> URL? {
        switch provider {
        case .binance:
            guard let symbol else { return nil }
            return URL(string: "\(AppConfiguration.API.binanceWebSocketURL)/\(symbol)@trade")
        case .okx:
            return URL(string: AppConfiguration.API.okxWebSocketURL)
        }
    }

    private func subscribeToOKXTickers(_ task: URLSessionWebSocketTask, symbols: Set<String>) {
        sendOKXSubscriptionMessage(task, operation: "subscribe", symbols: symbols)
    }

    private func unsubscribeFromOKXTickers(_ task: URLSessionWebSocketTask, symbols: Set<String>) {
        sendOKXSubscriptionMessage(task, operation: "unsubscribe", symbols: symbols)
    }

    private func sendOKXSubscriptionMessage(_ task: URLSessionWebSocketTask, operation: String, symbols: Set<String>) {
        let instruments = symbols.compactMap { symbol -> String? in
            Self.currenciesBySymbol[symbol]?.okxInstrumentID
        }

        guard !instruments.isEmpty else {
            return
        }

        let args = instruments.map { #"{"channel":"tickers","instId":"\#($0)"}"# }.joined(separator: ",")
        let message = #"{"op":"\#(operation)","args":[\#(args)]}"#

        task.send(.string(message)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeProvider == .okx else { return }
                guard self.okxWebSocketTask === task else { return }

                if let error {
                    self.logger.error("Failed to \(operation, privacy: .public) OKX tickers: \(error.localizedDescription, privacy: .public)")
                    self.okxWebSocketTask = nil

                    if operation == "subscribe" {
                        for symbol in symbols {
                            self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                        }
                    }

                    self.recordProviderFailure(.okx, context: "WebSocket \(operation)", error: error)
                    self.scheduleReconnect(provider: .okx)
                }
            }
        }
    }

    private func okxSymbols(from payload: [String: Any]) -> Set<String> {
        if let arg = payload["arg"] as? [String: Any],
           let instId = arg["instId"] as? String,
           let symbol = Self.symbolsByOKXInstrumentID[instId] {
            return [symbol]
        }

        if let dataArray = payload["data"] as? [[String: Any]] {
            return Set(
                dataArray.compactMap { ticker in
                    guard let instId = ticker["instId"] as? String else { return nil }
                    return Self.symbolsByOKXInstrumentID[instId]
                }
            )
        }

        return []
    }

    nonisolated private static func makeDecimalFormatter(maximumFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }

    nonisolated private static func validateBinanceTradeMessage(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data

        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else {
                throw WebSocketError.dataParsingFailed
            }
            data = textData
        case .data(let payload):
            data = payload
        @unknown default:
            throw WebSocketError.dataParsingFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["p"] as? String != nil else {
            throw WebSocketError.dataParsingFailed
        }
    }
}
