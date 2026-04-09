//
//  CryptoTickerApp.swift
//  CryptoTicker
//
//  Created by Luke Mao on 5/2/2025.
//

import AppKit
import Foundation
import os.log

@main
@MainActor
enum CryptoTickerApp {
    private static let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "CryptoTickerApp")
    private static var appDelegate: AppDelegate?

    static func main() {
        LaunchTrace.reset()
        LaunchTrace.write("main entered")

        guard AppConfiguration.validate() else {
            LaunchTrace.write("configuration validation failed")
            logger.fault("Configuration validation failed")
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        LaunchTrace.write("app delegate created")
        application.setActivationPolicy(.accessory)
        LaunchTrace.write("activation policy set")
        application.delegate = delegate
        LaunchTrace.write("delegate assigned; calling run")
        application.run()
        LaunchTrace.write("application.run returned")
    }
}

enum LaunchTrace {
    private static let fileURL = URL(fileURLWithPath: "/tmp/CryptoTicker-launch.log")

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}
