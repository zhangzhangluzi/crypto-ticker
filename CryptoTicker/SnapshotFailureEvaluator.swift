import Foundation

enum SnapshotFailureEvaluator {
    static func providerHealthFailure(
        from failures: [SnapshotFetchFailure],
        requestedSymbols: [String],
        selectedSymbols: [String]
    ) -> ProviderHealthFailure? {
        guard let firstFailure = failures.first else { return nil }

        if failures.count == requestedSymbols.count {
            return ProviderHealthFailure(context: "Snapshot refresh", error: firstFailure.underlyingError)
        }

        let failedSymbols = Set(failures.map(\.symbol))
        let failedSelectedSymbols = failedSymbols.intersection(selectedSymbols)
        guard let failedSelectedSymbol = failedSelectedSymbols.first,
              let failure = failures.first(where: { $0.symbol == failedSelectedSymbol }) else {
            return nil
        }

        return ProviderHealthFailure(
            context: "Snapshot refresh selected symbol \(failedSelectedSymbol) failed (\(failures.count)/\(requestedSymbols.count) failed)",
            error: failure.underlyingError
        )
    }
}
