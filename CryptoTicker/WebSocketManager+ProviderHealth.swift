import Foundation

extension WebSocketManager {
    func recordProviderSuccess(_ provider: MarketDataProvider, symbol: String? = nil) {
        if let symbol {
            setProviderFailureCount(0, provider: provider, symbol: symbol)
            if provider == .okx,
               selectedSymbols.allSatisfy({ providerFailureCount(provider: provider, symbol: $0) == 0 }) {
                setOKXUnavailable(false)
            }
            return
        }

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

    func recordProviderFailure(_ provider: MarketDataProvider, context: String, error: Error, symbol: String? = nil) {
        if let symbol {
            recordSymbolProviderFailure(provider, context: context, error: error, symbol: symbol)
            return
        }

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

    private func recordSymbolProviderFailure(_ provider: MarketDataProvider, context: String, error: Error, symbol: String) {
        let nextFailureCount = providerFailureCount(provider: provider, symbol: symbol) + 1
        setProviderFailureCount(nextFailureCount, provider: provider, symbol: symbol)

        logger.error("\(provider.displayName, privacy: .public) \(symbol, privacy: .public) failure #\(nextFailureCount) during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")

        let threshold: Int
        switch provider {
        case .binance:
            threshold = AppConfiguration.ProviderFallback.binanceFailureThreshold
            guard activeProvider == .binance, nextFailureCount >= threshold else { return }
            switchProvider(to: .okx, reason: "Binance \(symbol) failed \(nextFailureCount) times in a row")

        case .okx:
            threshold = AppConfiguration.ProviderFallback.okxFailureThreshold
            guard activeProvider == .okx, nextFailureCount >= threshold else { return }

            if selectedSymbols.allSatisfy({ providerFailureCount(provider: .okx, symbol: $0) >= threshold }) {
                logger.notice("OKX fallback became unavailable after selected symbols exceeded the failure threshold")
                setOKXUnavailable(true)
            }
        }
    }

    private func providerFailureCount(provider: MarketDataProvider, symbol: String) -> Int {
        providerFailureCountsBySymbol[provider]?[symbol] ?? 0
    }

    private func setProviderFailureCount(_ count: Int, provider: MarketDataProvider, symbol: String) {
        var providerFailures = providerFailureCountsBySymbol[provider] ?? [:]
        if count == 0 {
            providerFailures.removeValue(forKey: symbol)
        } else {
            providerFailures[symbol] = count
        }
        providerFailureCountsBySymbol[provider] = providerFailures
    }

    func startProviderRecoveryMonitor() {
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
}
