import Cocoa
import Darwin
import Foundation
import os.log

@MainActor
final class AppInstaller {
    private enum InstallerError: LocalizedError {
        case failedToCloseRunningCopy
        case failedToPrepareApplicationsFolder(String)

        var errorDescription: String? {
            switch self {
            case .failedToCloseRunningCopy:
                return "The installed copy could not be closed automatically."
            case .failedToPrepareApplicationsFolder(let path):
                return "Couldn't prepare the Applications folder at \(path)."
            }
        }
    }

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "AppInstaller")
    private let installedBundleName = "\(AppConfiguration.appName).app"

    func prepareForLaunch() -> Bool {
        let currentBundleURL = standardized(Bundle.main.bundleURL)

        guard !isInstalledApplication(at: currentBundleURL) else {
            return true
        }

        let destinationURL = preferredInstallURL()
        let shouldReplaceExistingInstall = fileManager.fileExists(atPath: destinationURL.path)

        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = shouldReplaceExistingInstall
            ? "Replace the installed copy of \(AppConfiguration.appName)?"
            : "Install \(AppConfiguration.appName) to Applications?"
        alert.informativeText = shouldReplaceExistingInstall
            ? "\(AppConfiguration.appName) can replace the existing copy in \(displayPath(for: destinationURL.deletingLastPathComponent())) and reopen it automatically."
            : "\(AppConfiguration.appName) can copy itself to \(displayPath(for: destinationURL.deletingLastPathComponent())) and reopen there automatically."
        alert.addButton(withTitle: shouldReplaceExistingInstall ? "Replace and Open" : "Install and Open")
        alert.addButton(withTitle: "Open Here")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try installCurrentApp(from: currentBundleURL, to: destinationURL)
                try scheduleRelaunch(of: destinationURL)
                logger.info("Installed app to \(destinationURL.path, privacy: .public)")
                NSApplication.shared.terminate(nil)
                return false
            } catch {
                logger.error("Installation failed: \(error.localizedDescription, privacy: .public)")
                presentInstallationFailure(error, destinationURL: destinationURL)
                return true
            }

        case .alertThirdButtonReturn:
            NSApplication.shared.terminate(nil)
            return false

        default:
            return true
        }
    }

    private func installCurrentApp(from currentBundleURL: URL, to destinationURL: URL) throws {
        try ensureParentDirectoryExists(for: destinationURL)
        try terminateInstalledCopies(at: destinationURL)

        let stagingDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedAppURL = stagingDirectoryURL.appendingPathComponent(installedBundleName, isDirectory: true)

        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectoryURL) }

        try fileManager.copyItem(at: currentBundleURL, to: stagedAppURL)
        removeQuarantineAttributeRecursively(at: stagedAppURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: stagedAppURL, to: destinationURL)
        removeQuarantineAttributeRecursively(at: destinationURL)
    }

    private func ensureParentDirectoryExists(for destinationURL: URL) throws {
        let parentDirectoryURL = destinationURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw InstallerError.failedToPrepareApplicationsFolder(parentDirectoryURL.path)
        }
    }

    private func terminateInstalledCopies(at destinationURL: URL) throws {
        let initialRunningCopies = runningInstalledCopies(at: destinationURL)
        guard !initialRunningCopies.isEmpty else { return }

        for runningApp in initialRunningCopies {
            if !runningApp.terminate() {
                _ = runningApp.forceTerminate()
            }
        }

        try waitForInstalledCopiesToExit(at: destinationURL)
    }

    private func waitForInstalledCopiesToExit(at destinationURL: URL) throws {
        let softDeadline = Date().addingTimeInterval(5)

        while Date() < softDeadline {
            if runningInstalledCopies(at: destinationURL).isEmpty {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        for runningApp in runningInstalledCopies(at: destinationURL) {
            _ = runningApp.forceTerminate()
        }

        let hardDeadline = Date().addingTimeInterval(2)

        while Date() < hardDeadline {
            if runningInstalledCopies(at: destinationURL).isEmpty {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw InstallerError.failedToCloseRunningCopy
    }

    private func runningInstalledCopies(at destinationURL: URL) -> [NSRunningApplication] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return []
        }

        let standardizedDestinationURL = standardized(destinationURL)

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { runningApp in
            guard runningApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleURL = runningApp.bundleURL else {
                return false
            }

            return standardized(bundleURL) == standardizedDestinationURL
        }
    }

    private func preferredInstallURL() -> URL {
        if let runningInstallURL = installCandidateURLs.first(where: { !runningInstalledCopies(at: $0).isEmpty }) {
            return runningInstallURL
        }

        if let existingInstallURL = installCandidateURLs.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existingInstallURL
        }

        return userApplicationsDirectory.appendingPathComponent(installedBundleName, isDirectory: true)
    }

    private func isInstalledApplication(at bundleURL: URL) -> Bool {
        let standardizedBundleURL = standardized(bundleURL)
        return installCandidateURLs.contains(where: { standardized($0) == standardizedBundleURL })
    }

    private var installCandidateURLs: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            userApplicationsDirectory
        ].map { $0.appendingPathComponent(installedBundleName, isDirectory: true) }
    }

    private var userApplicationsDirectory: URL {
        fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
    }

    private func scheduleRelaunch(of destinationURL: URL) throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "sleep 1; open -n \(shellQuoted(destinationURL.path))"]
        try launcher.run()
    }

    private func removeQuarantineAttributeRecursively(at rootURL: URL) {
        removeExtendedAttribute(named: "com.apple.quarantine", from: rootURL)

        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }

        for case let childURL as URL in enumerator {
            removeExtendedAttribute(named: "com.apple.quarantine", from: childURL)
        }
    }

    private func removeExtendedAttribute(named attributeName: String, from url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            removexattr(path, attributeName, 0)
        }
    }

    private func standardized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func displayPath(for url: URL) -> String {
        let homeDirectory = NSHomeDirectory()
        let path = url.path

        if path.hasPrefix(homeDirectory) {
            return "~" + path.dropFirst(homeDirectory.count)
        }

        return path
    }

    private func presentInstallationFailure(_ error: Error, destinationURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install \(AppConfiguration.appName)"
        alert.informativeText = "\(error.localizedDescription)\n\nYou can keep running the current copy, or move it manually to \(displayPath(for: destinationURL.deletingLastPathComponent()))."
        alert.runModal()
    }
}
