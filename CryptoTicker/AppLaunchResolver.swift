import AppKit
import Foundation
import os.log

@MainActor
final class AppLaunchResolver {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "AppLaunchResolver")

    func prepareForLaunch() -> Bool {
        let currentBundleURL = standardized(Bundle.main.bundleURL)

        guard let installedBundleURL = preferredLaunchBundleURL(for: currentBundleURL) else {
            return true
        }

        do {
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = [installedBundleURL.path]
            try launcher.run()

            logger.info(
                "Redirecting launch from \(currentBundleURL.path, privacy: .public) to installed app at \(installedBundleURL.path, privacy: .public)"
            )

            NSApplication.shared.terminate(nil)
            return false
        } catch {
            logger.error(
                "Failed to redirect launch to installed app at \(installedBundleURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private func preferredLaunchBundleURL(for currentBundleURL: URL) -> URL? {
        let canonicalBundleURL = standardized(systemInstallCandidateURL)

        if fileManager.fileExists(atPath: canonicalBundleURL.path),
           canonicalBundleURL != currentBundleURL {
            return canonicalBundleURL
        }

        let fallbackBundleURL = standardized(userInstallCandidateURL)
        if !isSystemInstallLocation(currentBundleURL),
           fileManager.fileExists(atPath: fallbackBundleURL.path),
           fallbackBundleURL != currentBundleURL {
            return fallbackBundleURL
        }

        return nil
    }

    private func isSystemInstallLocation(_ bundleURL: URL) -> Bool {
        standardized(bundleURL) == standardized(systemInstallCandidateURL)
    }

    private var systemInstallCandidateURL: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent("\(AppConfiguration.appName).app", isDirectory: true)
    }

    private var userInstallCandidateURL: URL {
        let userApplicationsURL = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true)

        return userApplicationsURL.appendingPathComponent("\(AppConfiguration.appName).app", isDirectory: true)
    }

    private func standardized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
