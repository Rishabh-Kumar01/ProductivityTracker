//
//  MenuBarView.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var tracker: ActivityTracker
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Today's Productivity Score
            HStack {
                Text("Today's Score")
                    .font(.headline)
                Spacer()
                Text("\(Int(tracker.todayScore))")
                    .font(.title2.bold())
                    .foregroundColor(scoreColor(tracker.todayScore))
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
            if tracker.topApps.isEmpty {
                Text("No activity yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(tracker.topApps) { app in
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

            // Open Dashboard (disabled for now)
            Button(action: {}) {
                Label("Open Dashboard", systemImage: "globe")
            }
            .disabled(true)

            // Settings (disabled for now)
            Button(action: {}) {
                Label("Settings...", systemImage: "gear")
            }
            .disabled(true)

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
        .frame(width: 280)
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
