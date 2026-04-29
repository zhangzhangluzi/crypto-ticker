import Foundation

extension WebSocketManager {
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

    nonisolated static func fetchPriceSnapshot(for symbol: String, provider: MarketDataProvider) async throws -> PriceSnapshot {
        switch provider {
        case .binance:
            return try await fetchBinancePriceSnapshot(for: symbol)
        case .okx:
            return try await fetchOKXPriceSnapshot(for: symbol)
        }
    }

    nonisolated static func fetchBinancePriceSnapshot(for symbol: String) async throws -> PriceSnapshot {
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

    nonisolated static func fetchOKXPriceSnapshot(for symbol: String) async throws -> PriceSnapshot {
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

        if failurePolicy == .updateProviderHealth,
           let providerFailure = SnapshotFailureEvaluator.providerHealthFailure(
            from: failures,
            requestedSymbols: symbols,
            selectedSymbols: selectedSymbols
           ) {
            recordProviderFailure(provider, context: providerFailure.context, error: providerFailure.error)

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

            let formattedPrice = MarketDataFormatter.formatPrice(snapshot.price)
            let formattedChange = MarketDataFormatter.formatPercent(snapshot.change) + "%"
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
}
