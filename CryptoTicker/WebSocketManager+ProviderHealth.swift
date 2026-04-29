import Foundation

extension WebSocketManager {
    func recordProviderSuccess(_ provider: MarketDataProvider) {
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

    func recordProviderFailure(_ provider: MarketDataProvider, context: String, error: Error) {
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
