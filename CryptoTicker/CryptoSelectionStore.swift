import Foundation

enum CryptoSelectionStore {
    static func load(
        from userDefaults: UserDefaults = .standard,
        key: String = AppConfiguration.UserDefaultsKeys.selectedCryptos,
        defaultSymbols: [String] = AppConfiguration.Defaults.selectedCryptos,
        validSymbols: Set<String> = Set(CryptoCurrency.availableCurrencies.map(\.symbol))
    ) -> [String] {
        let persistedSymbols = userDefaults.array(forKey: key) as? [String]
        return normalizedSelection(
            persistedSymbols,
            defaultSymbols: defaultSymbols,
            validSymbols: validSymbols
        )
    }

    static func save(
        _ symbols: [String],
        to userDefaults: UserDefaults = .standard,
        key: String = AppConfiguration.UserDefaultsKeys.selectedCryptos
    ) {
        userDefaults.set(symbols, forKey: key)
    }

    static func normalizedSelection(
        _ persistedSymbols: [String]?,
        defaultSymbols: [String],
        validSymbols: Set<String>
    ) -> [String] {
        let validPersistedSymbols = (persistedSymbols ?? defaultSymbols).filter { validSymbols.contains($0) }
        return validPersistedSymbols.isEmpty ? defaultSymbols : validPersistedSymbols
    }

    static func toggledSelection(_ symbol: String, in selectedSymbols: [String]) -> [String] {
        guard let index = selectedSymbols.firstIndex(of: symbol) else {
            return selectedSymbols + [symbol]
        }

        guard selectedSymbols.count > 1 else {
            return selectedSymbols
        }

        var nextSymbols = selectedSymbols
        nextSymbols.remove(at: index)
        return nextSymbols
    }
}
