//
//  CryptoTickerApp.swift
//  CryptoTicker
//
//  Created by Luke Mao on 5/2/2025.
//

import AppKit
import os.log

@main
@MainActor
enum CryptoTickerApp {
    private static let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "CryptoTickerApp")
    private static var appDelegate: AppDelegate?

    static func main() {
        guard AppConfiguration.validate() else {
            logger.fault("Configuration validation failed")
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}
