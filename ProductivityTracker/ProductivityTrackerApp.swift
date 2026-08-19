//
//  ProductivityTrackerApp.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import SwiftUI
import ServiceManagement
import Combine
import AppKit

@main
struct ProductivityTrackerApp: App {
    @ObservedObject private var tracker = ActivityTracker.shared
    @StateObject private var appState = AppState()

    init() {
        print("[DIAG] ProductivityTrackerApp.init() called at \(Date())")

        let _ = AlertManager.shared.fetchRules()
        
        // Start syncing data to cloud if logged in
        if AuthManager.shared.isLoggedIn {
            SyncManager.shared.startSync()
            BlocklistSyncManager.shared.start()
            DeviceRegistrar.shared.start()
            WallpaperManager.shared.start()
            AccountabilityManager.shared.checkStatus()
            HeartbeatManager.shared.start()
            InstalledAppSyncManager.shared.start()
            CategoryRuleSyncManager.shared.start()
            SSEManager.shared.connect()
        }

        // Watch for login state changes to start/stop sync
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UserDidLogin"),
            object: nil,
            queue: .main
        ) { _ in
            SyncManager.shared.startSync()
            BlocklistSyncManager.shared.start()
            DeviceRegistrar.shared.start()
            WallpaperManager.shared.start()
            AccountabilityManager.shared.checkStatus()
            HeartbeatManager.shared.start()
            InstalledAppSyncManager.shared.start()
            CategoryRuleSyncManager.shared.start()
            SSEManager.shared.connect()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UserDidLogout"),
            object: nil,
            queue: .main
        ) { _ in
            SyncManager.shared.stopSync()
            BlocklistSyncManager.shared.stop()
            AccountabilityManager.shared.checkStatus()
            HeartbeatManager.shared.stop()
            InstalledAppSyncManager.shared.stop()
            CategoryRuleSyncManager.shared.stop()
            SSEManager.shared.disconnect()
        }

        // Drop the SSE connection during sleep — macOS suspends the TCP socket anyway,
        // and the reconnect loop on wake picks up any changes made while asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            SSEManager.shared.disconnect()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard AuthManager.shared.isLoggedIn else { return }
            // Brief grace for the network stack to come back up after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                SSEManager.shared.connect()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            HeartbeatManager.shared.sendHeartbeat(isTerminating: true)
        }

        // Start tracking immediately on launch (not gated on menu bar click)
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            ActivityTracker.shared.startTracking()
        }
    }

    var body: some Scene {
        MenuBarExtra("Tracker", systemImage: "chart.bar.fill") {
            MenuBarView(tracker: tracker)
                .onAppear {
                    print("[DIAG] MenuBarExtra.onAppear fired at \(Date()) — isTracking: \(tracker.isTracking), onboarded: \(appState.hasCompletedOnboarding)")
                    if !appState.hasCompletedOnboarding {
                        appState.showOnboardingWindow(tracker: tracker)
                    }
                    // startTracking is handled at app launch in init().
                    // The guard in startTracking() makes any subsequent call a no-op.
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool

    private var onboardingWindow: NSWindow?

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func showOnboardingWindow(tracker: ActivityTracker) {
        guard onboardingWindow == nil else { return }

        let onboardingView = OnboardingView(isComplete: Binding(
            get: { [weak self] in
                self?.hasCompletedOnboarding ?? false
            },
            set: { [weak self] newValue in
                self?.hasCompletedOnboarding = newValue
                if newValue {
                    self?.dismissOnboardingWindow()
                    ActivityTracker.shared.startTracking()
                    try? SMAppService.mainApp.register()
                }
            }
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ProductivityTracker Setup"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }

    private func dismissOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}
