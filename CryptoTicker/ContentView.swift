//
//  ContentView.swift
//  CryptoTicker
//
//  Created by Luke Mao on 5/2/2025.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white, Color.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("CryptoTicker")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))

                    Text("Click once and it starts immediately.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("After launch, live prices stay in the menu bar at the top-right of your screen. Closing this window keeps CryptoTicker running there.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label("Open it later from Applications or Spotlight", systemImage: "app.badge")
                Label("Watch the top-right menu bar for CRYPTO TICKER or live prices", systemImage: "menubar.rectangle")
                Label("Closing this window does not quit the ticker", systemImage: "pin.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button("Continue in Menu Bar") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)

                Button("Open Applications Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 460, maxWidth: 460, minHeight: 280, idealHeight: 280, maxHeight: 320)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.orange.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
