import Foundation
import os.log

enum WebSocketError: Error {
    case invalidURL
    case connectionFailed
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

struct CryptoCurrency {
    let code: String
    let name: String
    let symbol: String
    let icon: String
    
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
    
    private var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private let urlSession = URLSession(configuration: .default)
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "WebSocketManager")
    
    let availableCurrencies = CryptoCurrency.availableCurrencies
    
    init() {
        loadSelectedCryptos()
        connectWebSockets()
        Task { await fetchAllCryptoPrices() }
    }

    private func loadSelectedCryptos() {
        let persistedSymbols = UserDefaults.standard.array(forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos) as? [String] ?? AppConfiguration.Defaults.selectedCryptos
        let validSymbols = persistedSymbols.filter { symbol in
            availableCurrencies.contains { $0.symbol == symbol }
        }
        selectedSymbols = validSymbols.isEmpty ? AppConfiguration.Defaults.selectedCryptos : validSymbols
    }
    
    private func saveSelectedCryptos() {
        UserDefaults.standard.set(selectedSymbols, forKey: AppConfiguration.UserDefaultsKeys.selectedCryptos)
    }

    func fetchAllCryptoPrices() async {
        logger.info("Fetching prices for all \(self.availableCurrencies.count) cryptocurrencies")

        var snapshots: [PriceSnapshot] = []

        await withTaskGroup(of: Result<PriceSnapshot, Error>.self) { group in
            for currency in availableCurrencies {
                group.addTask {
                    do {
                        return .success(try await Self.fetchPriceSnapshot(for: currency.symbol))
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
                    logger.error("Failed to fetch a cryptocurrency price: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        for snapshot in snapshots {
            prices[snapshot.symbol] = formatPrice(snapshot.price)
            priceChanges[snapshot.symbol] = formatPercent(snapshot.change) + "%"
        }

        NotificationCenter.default.post(name: .priceUpdated, object: nil)
        logger.info("Completed fetching all cryptocurrency prices")
    }

    nonisolated private static func fetchPriceSnapshot(for symbol: String) async throws -> PriceSnapshot {
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

    func connectWebSockets() {
        let symbolsToDisconnect = Set(webSocketTasks.keys).subtracting(Set(selectedSymbols))
        for symbol in symbolsToDisconnect {
            disconnectWebSocket(for: symbol)
        }

        for symbol in selectedSymbols {
            if webSocketTasks[symbol] == nil {
                connectWebSocket(for: symbol)
            }
        }
    }
    
    private func connectWebSocket(for symbol: String) {
        cancelReconnect(for: symbol)

        if let existingTask = webSocketTasks.removeValue(forKey: symbol) {
            existingTask.cancel(with: .goingAway, reason: nil)
        }

        guard let url = URL(string: "\(AppConfiguration.API.binanceWebSocketURL)/\(symbol)@trade") else {
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
    
    private func receiveMessage(for symbol: String) {
        guard let task = webSocketTasks[symbol] else { return }
        
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.selectedSymbols.contains(symbol) else { return }

                switch result {
                case .success(let message):
                    if case .connecting = self.connectionStates[symbol] {
                        self.updateConnectionState(for: symbol, state: .connected)
                    }

                    if case .string(let text) = message {
                        self.handleIncomingData(text, for: symbol)
                    } else {
                        self.logger.error("Unsupported WebSocket message received for \(symbol)")
                    }
                    self.receiveMessage(for: symbol)

                case .failure(let error):
                    self.logger.error("WebSocket error for \(symbol): \(error.localizedDescription, privacy: .public)")
                    self.webSocketTasks.removeValue(forKey: symbol)
                    self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                    self.scheduleReconnect(for: symbol)
                }
            }
        }
    }
    
    private func handleIncomingData(_ text: String, for symbol: String) {
        guard selectedSymbols.contains(symbol) else { return }
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let priceStr = json["p"] as? String else {
            logger.error("Failed to parse WebSocket data for \(symbol)")
            return
        }

        prices[symbol] = formatPrice(priceStr)
        NotificationCenter.default.post(name: .priceUpdated, object: nil)
    }
    
    private func updateConnectionState(for symbol: String, state: ConnectionState) {
        connectionStates[symbol] = state
        NotificationCenter.default.post(
            name: .connectionStateChanged,
            object: nil,
            userInfo: ["symbol": symbol, "state": state]
        )
    }
    
    func disconnectWebSockets() {
        logger.info("Disconnecting all WebSockets")
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
    }
    

    private func formatPrice(_ price: String) -> String {
        guard let priceDouble = Double(price) else { return price }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true

        formatter.maximumFractionDigits = {
            switch priceDouble {
            case 1000...: return 0  // >= 1000, no decimal digits
            case 1..<1000: return 2  // >= 1, 2 decimal digits
            default: return 4         // < 1, 4 decimal digits
            }
        }()

        return formatter.string(from: NSNumber(value: priceDouble)) ?? price
    }
    
    private func formatPercent(_ percent: String) -> String {
        guard let percentDouble = Double(percent) else { return percent }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"

        return formatter.string(from: NSNumber(value: percentDouble)) ?? percent
    }

    func getCurrency(for symbol: String) -> CryptoCurrency? {
        return availableCurrencies.first { $0.symbol == symbol }
    }
    
    func isConnected(for symbol: String) -> Bool {
        if case .connected = connectionStates[symbol] { return true }
        return false
    }

    private func scheduleReconnect(for symbol: String) {
        cancelReconnect(for: symbol)

        guard selectedSymbols.contains(symbol) else { return }

        reconnectTasks[symbol] = Task { [weak self] in
            let delay = UInt64(AppConfiguration.WebSocket.reconnectDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self = self else { return }

                self.reconnectTasks.removeValue(forKey: symbol)

                guard self.selectedSymbols.contains(symbol) else { return }
                self.connectWebSocket(for: symbol)
            }
        }
    }

    private func cancelReconnect(for symbol: String) {
        reconnectTasks[symbol]?.cancel()
        reconnectTasks.removeValue(forKey: symbol)
    }
}
