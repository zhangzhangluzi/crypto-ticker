import AppKit
import Foundation
import os.log

@MainActor
final class AppLaunchResolver {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "AppLaunchResolver")

    func prepareForLaunch() -> Bool {
        let currentBundleURL = standardized(Bundle.main.bundleURL)

        guard let installedBundleURL = preferredInstalledBundleURL(excluding: currentBundleURL) else {
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

    private func preferredInstalledBundleURL(excluding currentBundleURL: URL) -> URL? {
        guard !isInstalledLocation(currentBundleURL) else {
            return nil
        }

        return installCandidateURLs.first { candidateURL in
            let standardizedCandidateURL = standardized(candidateURL)
            return standardizedCandidateURL != currentBundleURL && fileManager.fileExists(atPath: standardizedCandidateURL.path)
        }
    }

    private func isInstalledLocation(_ bundleURL: URL) -> Bool {
        let standardizedBundleURL = standardized(bundleURL)
        return installCandidateURLs.contains { standardized($0) == standardizedBundleURL }
    }

    private var installCandidateURLs: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
        ].map { $0.appendingPathComponent("\(AppConfiguration.appName).app", isDirectory: true) }
    }

    private func standardized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
