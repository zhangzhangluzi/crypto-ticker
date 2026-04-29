import XCTest
@testable import CryptoTicker

final class AppLaunchRedirectionPolicyTests: XCTestCase {
    func testRedirectsToNewerInstalledVersion() {
        XCTAssertTrue(
            AppLaunchRedirectionPolicy.shouldRedirect(
                from: AppBundleVersion(marketingVersion: "1.7.17", buildVersion: "35"),
                to: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                currentBundlePath: "/Users/example/Downloads/CryptoTicker.app"
            )
        )
    }

    func testRedirectsSameVersionOutsideDevelopmentBuilds() {
        XCTAssertTrue(
            AppLaunchRedirectionPolicy.shouldRedirect(
                from: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                to: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                currentBundlePath: "/Users/example/Downloads/CryptoTicker.app"
            )
        )
    }

    func testDoesNotRedirectSameVersionDevelopmentBuilds() {
        XCTAssertFalse(
            AppLaunchRedirectionPolicy.shouldRedirect(
                from: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                to: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                currentBundlePath: "/Users/example/Library/Developer/Xcode/DerivedData/CryptoTicker/Build/Products/Debug/CryptoTicker.app"
            )
        )
    }

    func testDoesNotRedirectToOlderInstalledVersion() {
        XCTAssertFalse(
            AppLaunchRedirectionPolicy.shouldRedirect(
                from: AppBundleVersion(marketingVersion: "1.7.18", buildVersion: "36"),
                to: AppBundleVersion(marketingVersion: "1.7.17", buildVersion: "35"),
                currentBundlePath: "/Users/example/Downloads/CryptoTicker.app"
            )
        )
    }
}
