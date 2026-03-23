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

    private var cancellables = Set<AnyCancellable>()
    private var titlePollTimer: Timer?
    private var idleObserver: NSObjectProtocol?

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
        "com.apple.finder",            // Optional: remove if you want Finder tracked
        "com.rishabh.ProductivityTracker",  // Don't track ourselves
    ]

    init(idleDetector: IdleDetector) {
        self.idleDetector = idleDetector
    }

    // MARK: - Start / Stop Tracking

    func startTracking() {
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
    }

    func stopTracking() {
        isTracking = false
        closeCurrentActivity()

        cancellables.removeAll()
        titlePollTimer?.invalidate()
        titlePollTimer = nil

        if let observer = idleObserver {
            NotificationCenter.default.removeObserver(observer)
            idleObserver = nil
        }

        idleDetector.stop()
    }

    // MARK: - App Switch Handling

    private func handleAppSwitch(_ app: NSRunningApplication) {
        guard !idleDetector.isIdle else { return }

        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let pid = app.processIdentifier

        // Skip excluded system processes
        if let bundleId, excludedBundleIds.contains(bundleId) {
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

    private func closeCurrentActivity() {
        guard let appName = currentAppName,
              let startTime = currentStartTime else { return }

        let endTime = Date()
        let duration = Int(endTime.timeIntervalSince(startTime))

        // Skip noise from rapid switching (< 1 second)
        guard duration >= 1 else {
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
