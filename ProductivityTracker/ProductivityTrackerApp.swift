//
//  ProductivityTrackerApp.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import SwiftUI
import ServiceManagement
import Combine

@main
struct ProductivityTrackerApp: App {
    @StateObject private var idleDetector: IdleDetector
    @StateObject private var tracker: ActivityTracker
    @StateObject private var appState = AppState()

    init() {
        let idle = IdleDetector(threshold: 300)
        _idleDetector = StateObject(wrappedValue: idle)
        _tracker = StateObject(wrappedValue: ActivityTracker(idleDetector: idle))
        
        let _ = AlertManager.shared.fetchRules()
        
        // Start syncing data to cloud if logged in
        if AuthManager.shared.isLoggedIn {
            SyncManager.shared.startSync()
        }
        
        // Watch for login state changes to start/stop sync
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UserDidLogin"),
            object: nil,
            queue: .main
        ) { _ in
            SyncManager.shared.startSync()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UserDidLogout"),
            object: nil,
            queue: .main
        ) { _ in
            SyncManager.shared.stopSync()
        }
    }

    var body: some Scene {
        MenuBarExtra("Tracker", systemImage: "chart.bar.fill") {
            MenuBarView(tracker: tracker)
                .onAppear {
                    if !appState.hasCompletedOnboarding {
                        appState.showOnboardingWindow(tracker: tracker)
                    } else if !tracker.isTracking {
                        tracker.startTracking()
                    }
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
                    tracker.startTracking()
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
