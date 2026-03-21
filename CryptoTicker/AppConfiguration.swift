//
//  AppConfiguration.swift
//  CryptoTicker
//
//  Created by Luke Mao on 5/2/2025.
//

import Foundation

struct AppConfiguration {
    static let appName = "CryptoTicker"
    static let version = "1.3.0"
    static let bundleIdentifier = "io.github.zhangzhangluzi.cryptoticker"

    struct API {
        static let binanceBaseURL = "https://api.binance.com/api/v3"
        static let binanceWebSocketURL = "wss://stream.binance.com:9443/ws"
    }

    struct UI {
        static let menuFont = "Menlo"
        static let menuFontSize: CGFloat = 12.0
        static let statusBarFont = "Menlo"
        static let statusBarFontSize: CGFloat = 12.0
    }

    struct WebSocket {
        static let reconnectDelay: TimeInterval = 5.0
        static let snapshotRefreshInterval: TimeInterval = 30.0
    }

    struct UserDefaultsKeys {
        static let selectedCryptos = "selectedCryptos"
    }

    struct Logging {
        static let subsystem = AppConfiguration.bundleIdentifier
    }

    struct Defaults {
        static let selectedCryptos = ["btcusdt"]
    }

    static func validate() -> Bool {
        guard URL(string: API.binanceBaseURL) != nil,
              URL(string: API.binanceWebSocketURL) != nil else {
            return false
        }
        return true
    }
}

extension Notification.Name {
    static let priceUpdated = Notification.Name("PriceUpdated")
    static let connectionStateChanged = Notification.Name("ConnectionStateChanged")
    static let selectedSymbolsChanged = Notification.Name("SelectedSymbolsChanged")
}

enum NotificationUserInfoKey {
    static let symbol = "symbol"
    static let symbols = "symbols"
    static let state = "state"
}
