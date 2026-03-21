# Crypto Ticker

<img width="424" height="251" alt="image" src="https://github.com/user-attachments/assets/cf46218a-7a20-4459-b82f-4fa84bdf0239" />

**CryptoTicker** is a lightweight macOS menu bar application that displays real-time Binance **USDT** spot prices from your menu bar.

## Features

- Real-time Crypto Prices
- Multi-Crypto Support
- 24h Price Percentage Change
- Automatic WebSocket Reconnects

## Requirements

- macOS 26.0 or later
- A recent Xcode version with the macOS SDK (for local builds)

## Installation

> [!NOTE]
> **Why not in the App Store?**  
> Because publishing apps cost money, and I’d rather **HODL** my crypto.

1. Download **`CryptoTicker.pkg`** from the [latest release](https://github.com/zhangzhangluzi/crypto-ticker/releases).
2. Run the installer package. It installs **CryptoTicker** into **Applications**, updates the existing copy in place, and launches it in the foreground for you.
3. If you use **`CryptoTicker.zip`** instead, the app will offer to install itself into **Applications** on first launch.
4. After launch, **CryptoTicker opens a small window** so you can see it started. Live prices then stay in the top-right menu bar, and closing the window keeps the ticker running there.
5. Open the app. macOS may warn that the app is from an unidentified developer.
   - Right-click **CryptoTicker** in Finder and choose **Open**.
   - Or go to **System Settings** → **Privacy & Security** and click **Open Anyway**.
6. If the release asset is still processing, use the development steps below to build from source.

## Development

1. Clone the repository.
2. Open `CryptoTicker.xcodeproj` in Xcode.
3. Build and run the `CryptoTicker` scheme.
