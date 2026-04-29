import Foundation

struct AppBundleVersion: Comparable, Equatable {
    let marketingVersion: String
    let buildVersion: String

    static func < (lhs: AppBundleVersion, rhs: AppBundleVersion) -> Bool {
        let marketingComparison = lhs.marketingVersion.compare(rhs.marketingVersion, options: .numeric)
        if marketingComparison != .orderedSame {
            return marketingComparison == .orderedAscending
        }

        return lhs.buildVersion.compare(rhs.buildVersion, options: .numeric) == .orderedAscending
    }
}

enum AppLaunchRedirectionPolicy {
    static func shouldRedirect(
        from currentVersion: AppBundleVersion?,
        to installedVersion: AppBundleVersion?,
        currentBundlePath: String
    ) -> Bool {
        switch (currentVersion, installedVersion) {
        case let (.some(currentVersion), .some(installedVersion)):
            if installedVersion > currentVersion {
                return true
            }

            return installedVersion == currentVersion && !isDevelopmentBundlePath(currentBundlePath)

        case (.none, .some):
            return true
        case (.some, .none), (.none, .none):
            return false
        }
    }

    static func isDevelopmentBundlePath(_ path: String) -> Bool {
        path.contains("/Library/Developer/Xcode/DerivedData/")
            || path.contains("/Build/Products/")
    }
}
