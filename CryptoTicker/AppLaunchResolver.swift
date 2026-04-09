import AppKit
import Foundation
import os.log

@MainActor
final class AppLaunchResolver {
    private struct BundleVersion: Comparable {
        let marketingVersion: String
        let buildVersion: String

        static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
            let marketingComparison = lhs.marketingVersion.compare(rhs.marketingVersion, options: .numeric)
            if marketingComparison != .orderedSame {
                return marketingComparison == .orderedAscending
            }

            return lhs.buildVersion.compare(rhs.buildVersion, options: .numeric) == .orderedAscending
        }
    }

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "AppLaunchResolver")

    func prepareForLaunch() -> Bool {
        let currentBundleURL = standardized(Bundle.main.bundleURL)

        guard let installedBundleURL = preferredLaunchBundleURL(for: currentBundleURL) else {
            return true
        }

        do {
            terminateRunningInstalledCopies(at: installedBundleURL)

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
           canonicalBundleURL != currentBundleURL,
           shouldRedirectLaunch(from: currentBundleURL, to: canonicalBundleURL) {
            return canonicalBundleURL
        }

        let fallbackBundleURL = standardized(userInstallCandidateURL)
        if !isSystemInstallLocation(currentBundleURL),
           fileManager.fileExists(atPath: fallbackBundleURL.path),
           fallbackBundleURL != currentBundleURL,
           shouldRedirectLaunch(from: currentBundleURL, to: fallbackBundleURL) {
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

    private func shouldRedirectLaunch(from currentBundleURL: URL, to installedBundleURL: URL) -> Bool {
        let currentVersion = bundleVersion(for: currentBundleURL)
        let installedVersion = bundleVersion(for: installedBundleURL)

        switch (currentVersion, installedVersion) {
        case let (.some(currentVersion), .some(installedVersion)):
            return installedVersion >= currentVersion
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        case (.none, .none):
            return true
        }
    }

    private func bundleVersion(for bundleURL: URL) -> BundleVersion? {
        guard let bundle = Bundle(url: bundleURL) else {
            return nil
        }

        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return BundleVersion(marketingVersion: marketingVersion, buildVersion: buildVersion)
    }

    private func terminateRunningInstalledCopies(at installedBundleURL: URL) {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let canonicalInstalledBundleURL = standardized(installedBundleURL)
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: AppConfiguration.bundleIdentifier)
            .filter { runningApp in
                guard runningApp.processIdentifier != currentProcessID,
                      let runningBundleURL = runningApp.bundleURL else {
                    return false
                }

                return standardized(runningBundleURL) == canonicalInstalledBundleURL
            }

        guard !runningApps.isEmpty else { return }

        for runningApp in runningApps {
            logger.info("Terminating running installed app copy with pid \(runningApp.processIdentifier)")
            _ = runningApp.terminate()
        }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if runningApps.allSatisfy(\.isTerminated) {
                return
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        for runningApp in runningApps where !runningApp.isTerminated {
            logger.notice("Force terminating running installed app copy with pid \(runningApp.processIdentifier)")
            _ = runningApp.forceTerminate()
        }
    }

    private func standardized(_ url: URL) -> URL {
        let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let normalizedPath = normalizedFirmlinkPath(normalizedURL.path)
        return URL(fileURLWithPath: normalizedPath, isDirectory: normalizedURL.hasDirectoryPath).standardizedFileURL
    }

    private func normalizedFirmlinkPath(_ path: String) -> String {
        let dataVolumePrefix = "/System/Volumes/Data"

        guard path == dataVolumePrefix || path.hasPrefix("\(dataVolumePrefix)/") else {
            return path
        }

        let suffix = String(path.dropFirst(dataVolumePrefix.count))
        return suffix.isEmpty ? "/" : suffix
    }
}
