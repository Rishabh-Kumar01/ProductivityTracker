//
//  ActivityTracker.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import Foundation
import Combine
import AppKit

// MARK: - Top App Summary

struct TopApp: Identifiable {
    let id = UUID()
    let appName: String
    let duration: Int  // seconds
}

// MARK: - Activity Tracker

class ActivityTracker: ObservableObject {
    @Published var todayScore: Double = 0.0
    @Published var topApps: [TopApp] = []
    @Published var topDomains: [(domain: String, duration: Int)] = []
    @Published var totalDuration: Int = 0
    @Published var isTracking = false

    static let shared = ActivityTracker()

    private var cancellables = Set<AnyCancellable>()
    private var titlePollTimer: Timer?
    private var diagnosticHeartbeatTimer: Timer?
    private var idleObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?

    // Current activity being tracked
    private var currentAppName: String?
    private var currentBundleId: String?
    private var currentWindowTitle: String?
    private var currentURL: String?
    private var currentStartTime: Date?
    private var currentPid: pid_t?

    private let idleDetector: IdleDetector
    private let browserURLTracker = BrowserURLTracker()

    // System processes to exclude from tracking
    private let excludedBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.screensaver",
        "com.apple.screencaptureui",
        "com.apple.UserNotificationCenter",
        "com.apple.dock",
        // "com.apple.finder" — intentionally removed to match AW/RT tracking scope
        "com.rishabh.ProductivityTracker",  // Don't track ourselves
    ]

    private init() {
        self.idleDetector = IdleDetector(threshold: 300)
    }

    // MARK: - Start / Stop Tracking

    func startTracking() {
        print("[DIAG] ActivityTracker.startTracking() called at \(Date())")
        guard !isTracking else { return }
        isTracking = true

        // Event-driven: fires only when active app changes
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                self?.handleAppSwitch(app)
            }
            .store(in: &cancellables)

        // Detect deactivation with no successor (desktop click, system modal)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self, !self.idleDetector.isIdle else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                guard let bundleId = app.bundleIdentifier, bundleId == self.currentBundleId else { return }

                // Grace period — if another app activates within 300ms, didActivate handles it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    if self.currentBundleId == bundleId && self.currentStartTime != nil {
                        print("[DIAG] Deactivation with no successor for: \(bundleId) — closing activity")
                        self.closeCurrentActivity()
                    }
                }
            }
            .store(in: &cancellables)

        // Lightweight poll for window title changes (2s interval, 0.5s tolerance)
        titlePollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true
        ) { [weak self] _ in
            self?.checkWindowTitle()
        }
        titlePollTimer?.tolerance = 0.5

        // Listen for idle state changes
        idleObserver = NotificationCenter.default.addObserver(
            forName: .idleStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isIdle = notification.userInfo?["isIdle"] as? Bool ?? false
            self?.handleIdleStateChange(isIdle: isIdle)
        }

        // Re-capture frontmost app after screen unlock
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isTracking else { return }
            print("[DIAG] Screen UNLOCKED — re-capturing frontmost app")
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                self.handleAppSwitch(frontApp)
            }
        }

        // Start idle detector
        idleDetector.start()

        // Initialize with currently active app
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            handleAppSwitch(frontApp)
        }

        // Load initial stats
        refreshStats()

        // Run browser URL diagnostic on startup
        browserURLTracker.runStartupDiagnostic()

        // Diagnostic heartbeat — confirms tracking loop is alive
        diagnosticHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            print("[DIAG] Heartbeat: isTracking=\(self.isTracking), currentApp=\(self.currentAppName ?? "none"), hasTimer=\(self.titlePollTimer != nil)")
        }
        diagnosticHeartbeatTimer?.tolerance = 5.0

        // Sleep — close current activity with backdated end time
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("[DIAG] SLEEP — closing current activity at \(Date()), currentApp: \(self.currentAppName ?? "none")")
                let idleTime = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: CGEventType(rawValue: ~0)!
                )
                let adjustedEnd = Date().addingTimeInterval(-min(idleTime, self.idleDetector.threshold))
                self.closeCurrentActivity(overrideEndTime: adjustedEnd)
            }
            .store(in: &cancellables)

        // Wake — RunLoop may have dropped our timers; recreate them and re-capture frontmost app
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.isTracking else { return }
                print("[DIAG] WAKE — restarting timers at \(Date()), hasTimer: \(self.titlePollTimer != nil), currentApp: \(self.currentAppName ?? "none")")

                self.titlePollTimer?.invalidate()
                self.titlePollTimer = Timer.scheduledTimer(
                    withTimeInterval: 2.0, repeats: true
                ) { [weak self] _ in
                    self?.checkWindowTitle()
                }
                self.titlePollTimer?.tolerance = 0.5

                self.diagnosticHeartbeatTimer?.invalidate()
                self.diagnosticHeartbeatTimer = Timer.scheduledTimer(
                    withTimeInterval: 60.0, repeats: true
                ) { [weak self] _ in
                    guard let self = self else { return }
                    print("[DIAG] Heartbeat: isTracking=\(self.isTracking), currentApp=\(self.currentAppName ?? "none"), hasTimer=\(self.titlePollTimer != nil)")
                }
                self.diagnosticHeartbeatTimer?.tolerance = 5.0

                self.idleDetector.stop()
                self.idleDetector.start()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    if let frontApp = NSWorkspace.shared.frontmostApplication {
                        self?.handleAppSwitch(frontApp)
                    }
                }
            }
            .store(in: &cancellables)
    }

    func stopTracking() {
        print("[DIAG] ActivityTracker.stopTracking() called at \(Date())")
        isTracking = false
        closeCurrentActivity()

        diagnosticHeartbeatTimer?.invalidate()
        diagnosticHeartbeatTimer = nil

        cancellables.removeAll()
        titlePollTimer?.invalidate()
        titlePollTimer = nil

        if let observer = idleObserver {
            NotificationCenter.default.removeObserver(observer)
            idleObserver = nil
        }

        if let observer = screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockObserver = nil
        }

        idleDetector.stop()
    }

    // MARK: - App Switch Handling

    private func handleAppSwitch(_ app: NSRunningApplication) {
        guard !idleDetector.isIdle else { return }

        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        print("[DIAG] App switch: \(appName) (pid: \(pid)) at \(Date()) — idle: \(idleDetector.isIdle)")

        // Skip excluded system processes
        if let bundleId, excludedBundleIds.contains(bundleId) {
            print("[DIAG] Skipping excluded app: \(bundleId)")
            return  // Keep previous activity running
        }

        // Close previous activity
        closeCurrentActivity()

        // Start new activity
        currentAppName = appName
        currentBundleId = bundleId
        currentPid = pid
        currentStartTime = Date()
        currentWindowTitle = getWindowTitle(pid: pid)

        // Query browser URL if this is a known browser
        if let bundleId, browserURLTracker.isBrowser(bundleId: bundleId) {
            currentURL = browserURLTracker.getURL(forBundleId: bundleId)
        } else {
            currentURL = nil
        }
    }

    // MARK: - Window Title Polling

    private func checkWindowTitle() {
        guard let pid = currentPid, !idleDetector.isIdle else { return }

        let newTitle = getWindowTitle(pid: pid)

        // For browsers, also check if URL changed
        var newURL: String? = nil
        if let bundleId = currentBundleId, browserURLTracker.isBrowser(bundleId: bundleId) {
            newURL = browserURLTracker.getURL(forBundleId: bundleId)
        }

        let titleChanged = newTitle != currentWindowTitle && newTitle != nil
        let urlChanged = newURL != currentURL && newURL != nil

        if titleChanged || urlChanged {
            print("[DIAG] Title/URL change detected — old: \(currentWindowTitle ?? "nil"), new: \(newTitle ?? "nil"), urlChanged: \(urlChanged)")
            // Title or URL changed — close current activity and start new one
            closeCurrentActivity()

            currentStartTime = Date()
            currentWindowTitle = newTitle ?? currentWindowTitle
            currentURL = newURL ?? currentURL
        }
    }

    private func getWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success else { return nil }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow as! AXUIElement,
            kAXTitleAttribute as CFString,
            &title
        ) == .success else { return nil }

        return title as? String
    }

    // MARK: - Activity Lifecycle

    private func closeCurrentActivity(overrideEndTime: Date? = nil) {
        guard let appName = currentAppName,
              let startTime = currentStartTime else { return }

        let endTime = overrideEndTime ?? Date()
        let duration = Int(endTime.timeIntervalSince(startTime))

        // Skip noise from rapid switching (< 1 second)
        guard duration >= 1 else {
            print("[DIAG] Dropped sub-1s activity: \(appName), duration: \(duration)s")
            resetCurrent()
            return
        }

        // Resolve category and score
        let domain = currentURL != nil ? BrowserURLTracker.extractDomain(from: currentURL!) : nil
        let resolved = CategoryEngine.shared.resolve(
            appName: appName,
            bundleId: currentBundleId,
            windowTitle: currentWindowTitle,
            domain: domain
        )
        print("[DIAG] Closing activity: \(appName), duration: \(duration)s, domain: \(domain ?? "nil"), category: \(resolved.category)")

        let record = ActivityRecord(
            appName: appName,
            bundleId: currentBundleId,
            windowTitle: currentWindowTitle,
            url: currentURL,
            domain: domain,
            category: resolved.category,
            productivityScore: resolved.score,
            startTime: startTime,
            endTime: endTime,
            duration: duration
        )

        // Save to SQLite
        do {
            try DatabaseManager.shared.insertActivity(record)
        } catch {
            print("Failed to insert activity: \(error)")
        }

        resetCurrent()
        refreshStats()
    }

    private func resetCurrent() {
        currentAppName = nil
        currentBundleId = nil
        currentWindowTitle = nil
        currentURL = nil
        currentStartTime = nil
        currentPid = nil
    }

    // MARK: - Idle Handling

    private func handleIdleStateChange(isIdle: Bool) {
        print("[DIAG] Idle state changed: isIdle=\(isIdle) at \(Date())")
        if isIdle {
            closeCurrentActivity()
        } else {
            // User returned — start tracking the frontmost app again
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                handleAppSwitch(frontApp)
            }
        }
    }

    // MARK: - Stats

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let score = try DatabaseManager.shared.getTodayProductivityScore()
                let total = try DatabaseManager.shared.getTodayTotalDuration()
                let activities = try DatabaseManager.shared.getTodayActivities()
                let domains = try DatabaseManager.shared.getTodayTopDomains()

                // Calculate top apps
                var appDurations: [String: Int] = [:]
                for act in activities {
                    appDurations[act.appName, default: 0] += act.duration
                }
                let top = appDurations
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { TopApp(appName: $0.key, duration: $0.value) }

                DispatchQueue.main.async {
                    self?.todayScore = score
                    self?.totalDuration = total
                    self?.topApps = Array(top)
                    self?.topDomains = domains
                }
            } catch {
                print("Failed to refresh stats: \(error)")
            }
        }
    }
}
