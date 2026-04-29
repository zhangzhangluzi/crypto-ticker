import Foundation

extension WebSocketManager {
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

    func disconnectAllBinanceWebSockets() {
        let symbols = Array(Set(webSocketTasks.keys).union(reconnectTasks.keys))
        symbols.forEach { disconnectWebSocket(for: $0) }
    }

    func disconnectOKXWebSocket(resetConnectionStates: Bool) {
        cancelOKXReconnect()
        cancelAllOKXConnectionTimeouts()

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

    func cancelAllConnectionTimeouts() {
        for task in connectionTimeoutTasks.values {
            task.cancel()
        }
        connectionTimeoutTasks.removeAll()
        cancelAllOKXConnectionTimeouts()
    }

    func scheduleReconnect(for symbol: String? = nil, provider: MarketDataProvider) {
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

    nonisolated static func probeBinanceRealtimeFeed(for symbol: String) async throws {
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
            cancelOKXConnectionTimeout(for: symbol)
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
            scheduleOKXConnectionTimeout(for: task, symbols: addedSymbols)
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
        scheduleConnectionTimeout(for: symbol, provider: .binance, task: task)
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
        scheduleOKXConnectionTimeout(for: task, symbols: symbols)
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
                    self.cancelConnectionTimeout(for: symbol)
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
            cancelConnectionTimeout(for: symbol)
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
                        self.handleOKXMessage(text, task: task)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            self.logger.error("Unsupported binary OKX WebSocket message")
                            self.receiveOKXMessages(task)
                            return
                        }
                        self.handleOKXMessage(text, task: task)
                    @unknown default:
                        self.logger.error("Unsupported OKX WebSocket message received")
                    }

                    if self.okxWebSocketTask === task {
                        self.receiveOKXMessages(task)
                    }

                case .failure(let error):
                    self.logger.error("OKX WebSocket error: \(error.localizedDescription, privacy: .public)")
                    self.cancelAllOKXConnectionTimeouts()
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

    private func handleOKXMessage(_ text: String, task: URLSessionWebSocketTask) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse OKX WebSocket data")
            return
        }

        if let event = json["event"] as? String {
            if event == "subscribe" {
                return
            }

            if event == "error" {
                let statusCode = Int(json["code"] as? String ?? "") ?? -1
                let error = WebSocketError.invalidResponse(statusCode)
                logger.error("OKX WebSocket subscription error: \(String(describing: json), privacy: .public)")
                let affectedSymbols = okxSymbols(from: json).isEmpty ? okxSubscribedSymbols : okxSymbols(from: json)

                if affectedSymbols == okxSubscribedSymbols {
                    cancelAllOKXConnectionTimeouts()
                    task.cancel(with: .goingAway, reason: nil)
                    okxWebSocketTask = nil
                } else {
                    for symbol in affectedSymbols {
                        cancelOKXConnectionTimeout(for: symbol)
                    }
                    okxSubscribedSymbols.subtract(affectedSymbols)
                }

                for symbol in affectedSymbols {
                    updateConnectionState(for: symbol, state: .error(error))
                }

                if okxWebSocketTask == nil || !hasConnectedSelectedOKXSymbol() {
                    recordProviderFailure(.okx, context: "WebSocket subscribe", error: error)
                    scheduleReconnect(provider: .okx)
                }
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
                cancelOKXConnectionTimeout(for: symbol)
                updateConnectionState(for: symbol, state: .connected)
            }

            updatePrice(priceStr, for: symbol)
        }
    }

    private func disconnectWebSocket(for symbol: String) {
        cancelReconnect(for: symbol)
        cancelConnectionTimeout(for: symbol)

        if let task = webSocketTasks.removeValue(forKey: symbol) {
            task.cancel(with: .goingAway, reason: nil)
        }

        updateConnectionState(for: symbol, state: .disconnected)
    }

    private func cancelOKXReconnect() {
        okxReconnectTask?.cancel()
        okxReconnectTask = nil
    }

    private func cancelReconnect(for symbol: String) {
        reconnectTasks[symbol]?.cancel()
        reconnectTasks.removeValue(forKey: symbol)
    }

    private func scheduleConnectionTimeout(for symbol: String, provider: MarketDataProvider, task: URLSessionWebSocketTask) {
        cancelConnectionTimeout(for: symbol)

        connectionTimeoutTasks[symbol] = Task { [weak self] in
            let delay = UInt64(AppConfiguration.WebSocket.connectionTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self = self else { return }
                guard self.activeProvider == provider,
                      self.selectedSymbols.contains(symbol),
                      self.webSocketTasks[symbol] === task,
                      case .connecting = self.connectionStates[symbol] else {
                    return
                }

                self.connectionTimeoutTasks.removeValue(forKey: symbol)
                self.webSocketTasks.removeValue(forKey: symbol)
                task.cancel(with: .goingAway, reason: nil)

                let error = URLError(.timedOut)
                self.logger.error("WebSocket connect timeout for \(symbol) on \(provider.displayName, privacy: .public)")
                self.updateConnectionState(for: symbol, state: .error(.networkError(error)))
                self.recordProviderFailure(provider, context: "WebSocket connect timeout", error: error)

                guard self.activeProvider == provider else { return }
                self.scheduleReconnect(for: symbol, provider: provider)
            }
        }
    }

    private func scheduleOKXConnectionTimeout(for task: URLSessionWebSocketTask, symbols: Set<String>) {
        for symbol in symbols {
            cancelOKXConnectionTimeout(for: symbol)

            okxConnectionTimeoutTasks[symbol] = Task { [weak self] in
                let delay = UInt64(AppConfiguration.WebSocket.connectionTimeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self = self else { return }
                    guard self.activeProvider == .okx,
                          self.okxWebSocketTask === task,
                          self.okxSubscribedSymbols.contains(symbol),
                          case .connecting = self.connectionStates[symbol] else {
                        return
                    }

                    self.cancelOKXConnectionTimeout(for: symbol)
                    self.okxSubscribedSymbols.remove(symbol)
                    self.unsubscribeFromOKXTickers(task, symbols: [symbol])

                    let error = URLError(.timedOut)
                    self.logger.error("OKX WebSocket first tick timeout for \(symbol, privacy: .public)")
                    self.updateConnectionState(for: symbol, state: .error(.networkError(error)))

                    guard !self.hasConnectedSelectedOKXSymbol(),
                          !self.hasConnectingSelectedOKXSymbol() else {
                        return
                    }

                    self.okxWebSocketTask = nil
                    task.cancel(with: .goingAway, reason: nil)
                    self.recordProviderFailure(.okx, context: "WebSocket connect timeout", error: error)

                    guard self.activeProvider == .okx else { return }
                    self.scheduleReconnect(provider: .okx)
                }
            }
        }
    }

    private func cancelConnectionTimeout(for symbol: String) {
        connectionTimeoutTasks[symbol]?.cancel()
        connectionTimeoutTasks.removeValue(forKey: symbol)
    }

    private func cancelOKXConnectionTimeout(for symbol: String) {
        okxConnectionTimeoutTasks[symbol]?.cancel()
        okxConnectionTimeoutTasks.removeValue(forKey: symbol)
    }

    private func cancelAllOKXConnectionTimeouts() {
        for task in okxConnectionTimeoutTasks.values {
            task.cancel()
        }
        okxConnectionTimeoutTasks.removeAll()
    }

    private func hasConnectedSelectedOKXSymbol() -> Bool {
        selectedSymbols.contains { symbol in
            if case .connected = connectionStates[symbol] {
                return true
            }
            return false
        }
    }

    private func hasConnectingSelectedOKXSymbol() -> Bool {
        selectedSymbols.contains { symbol in
            if case .connecting = connectionStates[symbol] {
                return true
            }
            return false
        }
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
                    self.cancelAllOKXConnectionTimeouts()
                    task.cancel(with: .goingAway, reason: nil)
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
