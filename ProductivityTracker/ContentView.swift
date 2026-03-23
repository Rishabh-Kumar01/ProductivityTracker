//
//  MenuBarView.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import SwiftUI
import ServiceManagement
import Combine

struct MenuBarView: View {
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var blockManager = BlockManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    
    @State private var dbScore: Double = 5.0
    @State private var dbTopApps: [DatabaseManager.TopApp] = []
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Today's Productivity Score
            HStack {
                Text("Today's Score")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f", dbScore))
                    .font(.title2.bold())
                    .foregroundColor(scoreColor(dbScore))
            }

            // Total tracked time
            HStack(spacing: 6) {
                Circle()
                    .fill(tracker.isTracking ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(tracker.isTracking ? "Tracking..." : "Paused")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatDuration(tracker.totalDuration))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Top 3 apps today
            if dbTopApps.isEmpty {
                Text("No activity yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(dbTopApps, id: \.appName) { app in
                    HStack {
                        Text(app.appName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(app.duration))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Open Dashboard
            Button(action: {
                if let url = URL(string: "http://localhost:5173") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("Open Dashboard", systemImage: "globe")
            }

            // Settings
            if #available(macOS 13.0, *) {
                SettingsLink {
                    Label("Settings...", systemImage: "gear")
                }
            } else {
                Button(action: {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }) {
                    Label("Settings...", systemImage: "gear")
                }
            }

            Divider()

            // Focus Mode toggle
            Toggle(isOn: $blockManager.isBlockingActive) {
                Label("Focus Mode (Block Apps/Websites)", systemImage: "moon.fill")
            }
            .tint(.purple)

            // Launch at Login toggle
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "arrow.right.circle")
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to update login item: \(error)")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            Divider()

            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "power")
            }
        }
        .padding()
        .frame(width: 250)
        .onAppear(perform: updateData)
        .onReceive(timer) { _ in updateData() }
    }
    
    private func updateData() {
        if let summary = try? DatabaseManager.shared.getTodaysSummary() {
            self.dbScore = summary.productivityScore
            self.dbTopApps = summary.topApps
        }
    }

    // MARK: - Helpers

    private func scoreColor(_ score: Double) -> Color {
        if score >= 70 { return .green }
        if score >= 40 { return .yellow }
        return .red
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
