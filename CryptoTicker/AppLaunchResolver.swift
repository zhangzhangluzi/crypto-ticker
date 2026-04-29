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
            if let runningInstalledApp = runningInstalledApplication(at: installedBundleURL, excluding: ProcessInfo.processInfo.processIdentifier) {
                if try openInstalledBundle(at: installedBundleURL, forceNewInstance: false) != 0 {
                    _ = runningInstalledApp.activate(options: [])
                }
                logger.info(
                    "Redirecting launch from \(currentBundleURL.path, privacy: .public) to running installed app at \(installedBundleURL.path, privacy: .public)"
                )
                NSApplication.shared.terminate(nil)
                return false
            }

            let terminationStatus = try openInstalledBundle(at: installedBundleURL, forceNewInstance: true)

            guard terminationStatus == 0 else {
                logger.error(
                    "Open returned non-zero status while redirecting to installed app at \(installedBundleURL.path, privacy: .public): \(terminationStatus)"
                )
                return true
            }

            guard waitForInstalledAppLaunch(at: installedBundleURL, excluding: ProcessInfo.processInfo.processIdentifier) else {
                logger.error(
                    "Installed app at \(installedBundleURL.path, privacy: .public) did not finish launching after redirect request"
                )
                return true
            }

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

    private func openInstalledBundle(at installedBundleURL: URL, forceNewInstance: Bool) throws -> Int32 {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = forceNewInstance ? ["-n", installedBundleURL.path] : [installedBundleURL.path]
        try launcher.run()
        launcher.waitUntilExit()
        return launcher.terminationStatus
    }

    private func runningInstalledApplication(at installedBundleURL: URL, excluding currentProcessID: Int32) -> NSRunningApplication? {
        let canonicalInstalledBundleURL = standardized(installedBundleURL)

        return NSRunningApplication.runningApplications(withBundleIdentifier: AppConfiguration.bundleIdentifier)
            .first { runningApp in
                guard runningApp.processIdentifier != currentProcessID,
                      !runningApp.isTerminated,
                      let runningBundleURL = runningApp.bundleURL else {
                    return false
                }

                return standardized(runningBundleURL) == canonicalInstalledBundleURL
            }
    }

    private func waitForInstalledAppLaunch(at installedBundleURL: URL, excluding currentProcessID: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)

        while Date() < deadline {
            if runningInstalledApplication(at: installedBundleURL, excluding: currentProcessID) != nil {
                return true
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return false
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

        return AppLaunchRedirectionPolicy.shouldRedirect(
            from: currentVersion,
            to: installedVersion,
            currentBundlePath: currentBundleURL.path
        )
    }

    private func bundleVersion(for bundleURL: URL) -> AppBundleVersion? {
        guard let bundle = Bundle(url: bundleURL) else {
            return nil
        }

        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return AppBundleVersion(marketingVersion: marketingVersion, buildVersion: buildVersion)
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
