//
//  AppDelegate.swift
//  CryptoTicker
//
//  Created by Luke Mao on 5/2/2025.
//

import Cocoa
import SwiftUI
import os.log

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    private let statusBarMenu = NSMenu()
    private let sourceMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var currencyMenuItems: [String: NSMenuItem] = [:]
    private var pendingMenuRefreshSymbols: Set<String> = []
    private var isMenuOpen = false
    private var shouldPresentMenuAfterLaunch = true
    private let appLaunchResolver = AppLaunchResolver()
    private lazy var webSocketManager = WebSocketManager()
    private let logger = Logger(subsystem: AppConfiguration.Logging.subsystem, category: "AppDelegate")

    private static let menuParagraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: 30, options: [:]),
            NSTextTab(textAlignment: .left, location: 80, options: [:]),
            NSTextTab(textAlignment: .left, location: 180, options: [:]),
            NSTextTab(textAlignment: .left, location: 280, options: [:]),
            NSTextTab(textAlignment: .left, location: 360, options: [:])
        ]
        return paragraphStyle.copy() as? NSParagraphStyle ?? paragraphStyle
    }()

    private static let menuBaseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: AppConfiguration.UI.menuFont, size: AppConfiguration.UI.menuFontSize) ?? NSFont.monospacedSystemFont(ofSize: AppConfiguration.UI.menuFontSize, weight: .regular),
        .paragraphStyle: menuParagraphStyle
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application launching...")

        guard appLaunchResolver.prepareForLaunch() else {
            logger.info("Launch redirected to installed app copy")
            return
        }

        setupStatusBarItem()
        setupMenu()
        setupObservers()
        refreshDisplay(forceMenuRefresh: true, forceStatusBarRefresh: true)
        presentStatusMenuIfNeeded()
        logger.info("Application launched successfully")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating...")
        NotificationCenter.default.removeObserver(self)
        webSocketManager.disconnectWebSockets()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentStatusMenu()
        return false
    }

    private func setupStatusBarItem() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusBarItem.button else {
            logger.error("Failed to create status bar button")
            return
        }
        
        button.title = "Loading..."
        button.font = NSFont(name: AppConfiguration.UI.statusBarFont, size: AppConfiguration.UI.statusBarFontSize)
        
        logger.info("Status bar item created")
    }
    
    private func setupMenu() {
        statusBarMenu.delegate = self
        statusBarMenu.removeAllItems()
        currencyMenuItems.removeAll()

        updateSourceMenuItem()
        statusBarMenu.addItem(sourceMenuItem)
        statusBarMenu.addItem(.separator())

        for currency in webSocketManager.availableCurrencies {
            let item = createCurrencyMenuItem(for: currency)
            currencyMenuItems[currency.symbol] = item
            statusBarMenu.addItem(item)
        }
        
        statusBarMenu.addItem(.separator())
        statusBarMenu.addItem(createQuitMenuItem())
        statusBarItem.menu = statusBarMenu
    }

    private func presentStatusMenuIfNeeded() {
        guard shouldPresentMenuAfterLaunch else { return }
        shouldPresentMenuAfterLaunch = false

        DispatchQueue.main.async { [weak self] in
            self?.presentStatusMenu()
        }
    }

    private func presentStatusMenu() {
        guard let button = statusBarItem.button,
              let window = button.window else {
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        let menuOrigin = NSPoint(
            x: buttonRectOnScreen.maxX - statusBarMenu.size.width,
            y: buttonRectOnScreen.minY - 4
        )

        statusBarMenu.popUp(positioning: nil, at: menuOrigin, in: nil)
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePriceUpdated(_:)),
            name: .priceUpdated,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionStateChanged(_:)),
            name: .connectionStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectedSymbolsChanged(_:)),
            name: .selectedSymbolsChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProviderChanged(_:)),
            name: .providerChanged,
            object: nil
        )
    }

    private func createCurrencyMenuItem(for currency: CryptoCurrency) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(toggleCrypto(_:)), keyEquivalent: "")
        item.representedObject = currency.symbol
        item.target = self
        updateCurrencyMenuItem(item, for: currency)
        
        return item
    }
    
    private func createQuitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        item.target = self
        return item
    }

    private func updateCurrencyMenuItem(_ item: NSMenuItem, for currency: CryptoCurrency) {
        let price = webSocketManager.prices[currency.symbol] ?? "Loading..."
        let change = webSocketManager.priceChanges[currency.symbol] ?? "-"
        let isSelected = webSocketManager.selectedSymbols.contains(currency.symbol)
        let isConnected = webSocketManager.isConnected(for: currency.symbol)

        item.title = formatCurrencyTitle(
            code: currency.code,
            name: currency.name,
            price: price,
            change: change,
            icon: currency.icon,
            isConnected: isConnected
        )
        item.state = isSelected ? .on : .off
        item.attributedTitle = createAttributedTitle(
            code: currency.code,
            name: currency.name,
            price: price,
            change: change,
            icon: currency.icon,
            isConnected: isConnected
        )
    }

    private func refreshMenuItems(for symbols: Set<String>) {
        for symbol in symbols {
            guard let item = currencyMenuItems[symbol],
                  let currency = webSocketManager.getCurrency(for: symbol) else {
                continue
            }
            updateCurrencyMenuItem(item, for: currency)
        }
    }

    private func formatCurrencyTitle(code: String, name: String, price: String, change: String, icon: String, isConnected: Bool) -> String {
        let status = isConnected ? "●" : "○"
        return "\(status) \(icon) \(code) - \(name) - \(price) USDT (\(change))"
    }
    
    private func createAttributedTitle(code: String, name: String, price: String, change: String, icon: String, isConnected: Bool) -> NSAttributedString {
        let statusColor: NSColor = isConnected ? .systemGreen : .systemRed
        let changeColor = color(forPriceChange: change)
        
        let status = isConnected ? "●" : "○"
        let fullText = "\(status)\t\(icon) \(code)\t\(name)\t\(price) USDT\t\(change)"
        
        let attributedString = NSMutableAttributedString(string: fullText, attributes: Self.menuBaseAttributes)

        attributedString.addAttribute(.foregroundColor, value: statusColor, range: NSRange(location: 0, length: 1))

        if let changeRange = fullText.range(of: change) {
            let nsRange = NSRange(changeRange, in: fullText)
            attributedString.addAttribute(.foregroundColor, value: changeColor, range: nsRange)
        }
        
        return attributedString
    }

    private func color(forPriceChange change: String) -> NSColor {
        if change == "-" {
            return .secondaryLabelColor
        }
        return change.hasPrefix("-") ? .systemRed : .systemGreen
    }

    private func updateStatusBarTitle() {
        guard let button = statusBarItem.button else { return }
        
        let displayText = createStatusBarDisplayText()
        button.title = displayText
    }
    
    private func createStatusBarDisplayText() -> String {
        let selectedPrices = webSocketManager.selectedSymbols.compactMap { symbol -> String? in
            guard let currency = webSocketManager.getCurrency(for: symbol) else {
                return nil
            }

            let connectionIndicator: String
            switch webSocketManager.connectionStates[symbol] {
            case .connected:
                connectionIndicator = ""
            case .connecting:
                connectionIndicator = "⏳"
            case .disconnected, .error, .none:
                connectionIndicator = "⚠️"
            }

            let price = webSocketManager.prices[symbol] ?? "--"
            return "\(currency.code) \(price) \(connectionIndicator)".trimmingCharacters(in: .whitespaces)
        }

        let providerPrefix = webSocketManager.isUsingFallbackProvider ? "[OKX] " : ""
        let baseText = selectedPrices.isEmpty ? "CRYPTO TICKER" : selectedPrices.joined(separator: " | ")
        return providerPrefix + baseText
    }

    private func updateSourceMenuItem() {
        sourceMenuItem.title = webSocketManager.providerStatusText
        sourceMenuItem.isEnabled = false
    }

    @objc private func toggleCrypto(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else {
            logger.error("Invalid symbol in menu item")
            return
        }
        
        webSocketManager.toggleCryptoSelection(symbol)
    }
    
    private func notificationSymbols(from notification: Notification) -> Set<String>? {
        if let symbols = notification.userInfo?[NotificationUserInfoKey.symbols] as? [String] {
            return Set(symbols)
        }

        if let symbol = notification.userInfo?[NotificationUserInfoKey.symbol] as? String {
            return [symbol]
        }

        return nil
    }

    private func refreshDisplay(
        for symbols: Set<String>? = nil,
        forceMenuRefresh: Bool = false,
        forceStatusBarRefresh: Bool = false
    ) {
        if forceStatusBarRefresh || shouldRefreshStatusBar(for: symbols) {
            updateStatusBarTitle()
        }

        let symbolsToRefresh = symbols ?? Set(currencyMenuItems.keys)
        guard !symbolsToRefresh.isEmpty else { return }

        if forceMenuRefresh || isMenuOpen {
            refreshMenuItems(for: symbolsToRefresh)
            pendingMenuRefreshSymbols.subtract(symbolsToRefresh)
        } else {
            pendingMenuRefreshSymbols.formUnion(symbolsToRefresh)
        }
    }

    private func shouldRefreshStatusBar(for symbols: Set<String>?) -> Bool {
        guard let symbols else { return true }
        let selectedSymbolSet = Set(webSocketManager.selectedSymbols)
        return !selectedSymbolSet.isDisjoint(with: symbols)
    }

    @objc private func handlePriceUpdated(_ notification: Notification) {
        refreshDisplay(for: notificationSymbols(from: notification))
    }

    @objc private func handleConnectionStateChanged(_ notification: Notification) {
        refreshDisplay(for: notificationSymbols(from: notification))
    }

    @objc private func handleSelectedSymbolsChanged(_ notification: Notification) {
        refreshDisplay(
            for: notificationSymbols(from: notification),
            forceMenuRefresh: isMenuOpen,
            forceStatusBarRefresh: true
        )
    }

    @objc private func handleProviderChanged(_ notification: Notification) {
        updateSourceMenuItem()
        refreshDisplay(forceMenuRefresh: isMenuOpen, forceStatusBarRefresh: true)
    }
    
    @objc private func quitApp() {
        logger.info("Quit requested")
        webSocketManager.disconnectWebSockets()
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true

        if !pendingMenuRefreshSymbols.isEmpty {
            let dirtySymbols = pendingMenuRefreshSymbols
            pendingMenuRefreshSymbols.removeAll()
            refreshMenuItems(for: dirtySymbols)
        }

        Task {
            await webSocketManager.refreshMenuDataIfNeeded()
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}
