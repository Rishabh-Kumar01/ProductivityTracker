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
    
    @State private var dbScore: Double = 2.0
    @State private var dbTopApps: [DatabaseManager.TopApp] = []
    @State private var dbTopDomains: [(domain: String, duration: Int)] = []
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Today's Productivity Score
            HStack {
                Text("Today's Score")
                    .font(.headline)
                Spacer()
                Text("\(Int((dbScore / 4.0) * 100))%")
                    .font(.title2.bold())
                    .foregroundColor(scoreColor(dbScore))
            }

            // Total tracked time. The dot reports whether we are actually
            // capturing, not merely whether the timer is alive — the latter
            // stayed green all through the title-change data loss.
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatDuration(tracker.totalDuration))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Only rendered when something is actually wrong.
            if let detail = tracker.captureHealth.detail {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(statusColor)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .broken = tracker.captureHealth {
                            Button("Open Privacy Settings") {
                                openAccessibilitySettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Blocking enforcement. Separate from capture health: tracking can be
            // perfect while /etc/hosts silently disagrees with the database.
            if let detail = blockManager.blockHealth.detail {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "shield.slash.fill")
                        .foregroundColor(blockStatusColor)
                        .font(.caption)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
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

            // Top 3 domains today
            if !dbTopDomains.isEmpty {
                Label("Top Websites", systemImage: "globe.americas")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                
                ForEach(dbTopDomains, id: \.domain) { dom in
                    HStack {
                        Text(dom.domain)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(dom.duration))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
            }

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
        if let domains = try? DatabaseManager.shared.getTodayTopDomains() {
            self.dbTopDomains = domains
        }
    }

    // MARK: - Helpers

    private var blockStatusColor: Color {
        switch blockManager.blockHealth {
        case .ok: return .green
        case .degraded: return .yellow
        case .broken: return .red
        }
    }

    private var statusColor: Color {
        guard tracker.isTracking else { return .gray }
        switch tracker.captureHealth {
        case .ok: return .green
        case .degraded: return .yellow
        case .broken: return .red
        }
    }

    private var statusLabel: String {
        guard tracker.isTracking else { return "Paused" }
        switch tracker.captureHealth {
        case .ok: return "Tracking..."
        case .degraded: return "Tracking (partial)"
        case .broken: return "Not recording"
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        // score is raw 0-4
        if score >= 3 { return .green }
        if score >= 2 { return .yellow }
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
