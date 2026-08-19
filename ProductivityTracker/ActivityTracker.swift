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

// MARK: - Capture Health

/// Whether tracking is actually *capturing*, as opposed to merely running.
/// `isTracking` only reports that the timer is alive — it stayed green for
/// months during the title-change bug while ~90% of segments were dropped.
enum CaptureHealth: Equatable {
    case ok
    /// Working, but some signal is missing (e.g. browser URLs).
    case degraded(String)
    /// Recording is compromised.
    case broken(String)

    var isOK: Bool { self == .ok }

    var detail: String? {
        switch self {
        case .ok: return nil
        case .degraded(let m), .broken(let m): return m
        }
    }
}

// MARK: - Activity Tracker

class ActivityTracker: ObservableObject {
    @Published var todayScore: Double = 0.0
    @Published var topApps: [TopApp] = []
    @Published var topDomains: [(domain: String, duration: Int)] = []
    @Published var totalDuration: Int = 0
    @Published var isTracking = false
    @Published var captureHealth: CaptureHealth = .ok

    static let shared = ActivityTracker()

    private var cancellables = Set<AnyCancellable>()
    private var titlePollTimer: Timer?
    private var diagnosticHeartbeatTimer: Timer?
    private var idleObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?

    // MARK: Tuning

    /// How often the frontmost app is sampled. The old design polled only the
    /// title of the app it already believed was frontmost; this asks the system
    /// what is actually in front. ActivityWatch's macOS watcher polls at 10s,
    /// so 2s is conservative.
    private let pollInterval: TimeInterval = 2.0
    /// Largest gap between two samples that still counts as one continuous
    /// segment. Anything longer — missed ticks, timer coalescing, sleep — opens
    /// a fresh row rather than inventing the time in between.
    private let pulsetime: TimeInterval = 6.0
    /// Segments are capped so the open row is never stale for long. Bounds
    /// dashboard lag and crash loss, and keeps startTime unique per app, which
    /// the server's ON CONFLICT (user_id, platform, app_name, start_time) rule
    /// depends on.
    private let maxSegmentLength: TimeInterval = 300
    /// How often the open row's end is written to SQLite. A crash costs at most
    /// this much of the segment in flight.
    private let flushInterval: TimeInterval = 10.0

    // MARK: Open segment state

    /// Everything that distinguishes one segment from the next. A change in any
    /// field seals the open row and starts a new one.
    private struct SegmentKey: Equatable {
        let appName: String
        let bundleId: String?
        let windowTitle: String?
        let url: String?
        let isIdle: Bool
    }

    /// Start of the current coverage measurement window. Reset on wake, so
    /// time asleep isn't counted as time we failed to record.
    private var trackingStartedAt: Date?

    /// The row currently being extended. `openEnd` is the last confirmed
    /// observation, `lastFlush` the last write to disk. Note that no duration
    /// is held here — it is always derived from start and end, which is what
    /// makes losing this state cost one poll interval instead of hours.
    private var openId: String?
    private var openKey: SegmentKey?
    private var openStart: Date?
    private var openEnd: Date?
    private var lastFlush: Date?

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
        trackingStartedAt = Date()

        // Recover rows left open by a crash or force-quit before sampling again.
        try? DatabaseManager.shared.finalizeOrphanedOpenRows()

        // App switches only make the boundary sharp — the poll below is the
        // source of truth, so a dropped notification self-corrects in one tick.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pollTick()
            }
            .store(in: &cancellables)

        // Deactivation with no successor (desktop click, system modal). The tick
        // reads whatever is really frontmost, so this just runs one early.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.pollTick()
                }
            }
            .store(in: &cancellables)

        // The authoritative sample.
        titlePollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            self?.pollTick()
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
            print("[DIAG] Screen UNLOCKED — re-sampling frontmost app")
            self.pollTick()
        }

        // Start idle detector
        idleDetector.start()

        // Take the first sample immediately rather than waiting a full interval.
        pollTick()

        // Load initial stats
        refreshStats()

        // Run browser URL diagnostic on startup
        browserURLTracker.runStartupDiagnostic()

        // Diagnostic heartbeat — confirms tracking loop is alive
        diagnosticHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            print("[DIAG] Heartbeat: isTracking=\(self.isTracking), currentApp=\(self.openKey?.appName ?? "none"), hasTimer=\(self.titlePollTimer != nil)")
            self.checkCaptureHealth()
        }
        diagnosticHeartbeatTimer?.tolerance = 5.0

        // Sleep — close current activity with backdated end time
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("[DIAG] SLEEP — sealing open segment at \(Date()), currentApp: \(self.openKey?.appName ?? "none")")
                let adjustedEnd = Date().addingTimeInterval(
                    -min(self.currentIdleSeconds(), self.idleDetector.threshold)
                )
                self.finalizeOpenSegment(at: adjustedEnd)
            }
            .store(in: &cancellables)

        // Wake — RunLoop may have dropped our timers; recreate them and re-capture frontmost app
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.isTracking else { return }
                print("[DIAG] WAKE — restarting timers at \(Date()), hasTimer: \(self.titlePollTimer != nil), currentApp: \(self.openKey?.appName ?? "none")")

                // Time asleep would otherwise read as time we failed to record.
                self.trackingStartedAt = Date()

                self.titlePollTimer?.invalidate()
                self.titlePollTimer = Timer.scheduledTimer(
                    withTimeInterval: self.pollInterval, repeats: true
                ) { [weak self] _ in
                    self?.pollTick()
                }
                self.titlePollTimer?.tolerance = 0.5

                self.diagnosticHeartbeatTimer?.invalidate()
                self.diagnosticHeartbeatTimer = Timer.scheduledTimer(
                    withTimeInterval: 60.0, repeats: true
                ) { [weak self] _ in
                    guard let self = self else { return }
                    print("[DIAG] Heartbeat: isTracking=\(self.isTracking), currentApp=\(self.openKey?.appName ?? "none"), hasTimer=\(self.titlePollTimer != nil)")
                    self.checkCaptureHealth()
                }
                self.diagnosticHeartbeatTimer?.tolerance = 5.0

                self.idleDetector.stop()
                self.idleDetector.start()

                // The wake gap exceeds pulsetime, so this opens a fresh segment
                // rather than back-filling the time the machine was asleep.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.pollTick()
                }
            }
            .store(in: &cancellables)
    }

    func stopTracking() {
        print("[DIAG] ActivityTracker.stopTracking() called at \(Date())")
        isTracking = false
        captureHealth = .ok
        finalizeOpenSegment()

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

    // MARK: - Poll

    /// One sample of the world. Asks the system what is frontmost — never trusts
    /// remembered identity — then either extends the open row or seals it and
    /// opens the next. This is the only place segments are created.
    /// `backdate` starts the new segment earlier than the sample instant, used
    /// when idle is detected after the fact — the away time belongs to the idle
    /// row, not to the active one that preceded it.
    private func pollTick(backdatingStartTo backdate: Date? = nil) {
        guard isTracking else { return }
        let now = Date()

        guard let front = NSWorkspace.shared.frontmostApplication else {
            // Nothing frontmost (login window, fast user switch). Seal and wait.
            finalizeOpenSegment(at: now)
            return
        }

        let bundleId = front.bundleIdentifier

        // Excluded apps must not chop a segment in half — clicking our own menu
        // bar icon shouldn't end your Xcode session. Keep extending what's open.
        if let bundleId, excludedBundleIds.contains(bundleId) {
            extendOpenSegment(to: now)
            return
        }

        let isIdle = idleDetector.isIdle
        var windowTitle: String?
        var url: String?

        if isIdle, let open = openKey, open.bundleId == bundleId {
            // Don't drive the Accessibility API or AppleScript while the user is
            // away — reuse the last known state so an idle stretch stays one row
            // instead of a run of nil-title ones.
            windowTitle = open.windowTitle
            url = open.url
        } else {
            windowTitle = getWindowTitle(pid: front.processIdentifier)
            if let bundleId, browserURLTracker.isBrowser(bundleId: bundleId) {
                url = browserURLTracker.getURL(forBundleId: bundleId)
            }

            // Both lookups fail transiently — AX misses a focused window, or the
            // browser is inside its Automation-denied backoff. Treat nil as
            // "unchanged" rather than as a new state, otherwise the segment
            // splits on every other tick and the row count explodes.
            if let open = openKey, open.bundleId == bundleId {
                if windowTitle == nil { windowTitle = open.windowTitle }
                if url == nil { url = open.url }
            }
        }

        let key = SegmentKey(
            appName: front.localizedName ?? "Unknown",
            bundleId: bundleId,
            windowTitle: windowTitle,
            url: url,
            isIdle: isIdle
        )

        let sameState = key == openKey
        let withinPulse = openEnd.map { now.timeIntervalSince($0) <= pulsetime } ?? false
        let underCap = openStart.map { now.timeIntervalSince($0) < maxSegmentLength } ?? false

        if sameState && withinPulse && underCap {
            extendOpenSegment(to: now)
        } else {
            // Seal at `now` rather than at the last sample so no time is dropped
            // between segments. The boundary can be off by up to one interval,
            // but app switches tick immediately on notification, so in practice
            // that only applies to title changes.
            finalizeOpenSegment(at: now)
            openSegment(key: key, at: backdate ?? now, observedThrough: now)
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

    /// Writes a new row immediately, marked open, and starts extending it. The
    /// row exists on disk from its first instant, so a crash costs at most one
    /// flush interval rather than the whole segment.
    private func openSegment(key: SegmentKey, at start: Date, observedThrough end: Date? = nil) {
        let observedEnd = max(end ?? start, start)
        let domain = key.url.flatMap { BrowserURLTracker.extractDomain(from: $0) }
        let resolved = CategoryEngine.shared.resolve(
            appName: key.appName,
            bundleId: key.bundleId,
            windowTitle: key.windowTitle,
            domain: domain
        )

        let record = ActivityRecord(
            appName: key.appName,
            bundleId: key.bundleId,
            windowTitle: key.windowTitle,
            url: key.url,
            domain: domain,
            category: resolved.category,
            productivityScore: resolved.score,
            startTime: start,
            endTime: observedEnd,
            duration: Int(observedEnd.timeIntervalSince(start)),
            isIdle: key.isIdle,
            isOpen: true
        )

        do {
            try DatabaseManager.shared.insertActivity(record)
        } catch {
            print("Failed to open activity: \(error)")
            return
        }

        print("[DIAG] Opened segment: \(key.appName), title: \(key.windowTitle ?? "nil"), domain: \(domain ?? "nil"), idle: \(key.isIdle)")

        openId = record.id
        openKey = key
        openStart = start
        openEnd = observedEnd
        lastFlush = observedEnd
    }

    /// Pushes the open row's end forward. Written to disk on `flushInterval`
    /// rather than every tick — the in-memory end is authoritative between
    /// flushes, and finalize always writes the exact value.
    private func extendOpenSegment(to now: Date) {
        guard let id = openId, let start = openStart else { return }
        openEnd = now

        if let last = lastFlush, now.timeIntervalSince(last) < flushInterval { return }
        lastFlush = now

        do {
            try DatabaseManager.shared.extendOpenActivity(
                id: id,
                endTime: now,
                duration: Int(now.timeIntervalSince(start))
            )
        } catch {
            print("Failed to extend activity: \(error)")
        }
        refreshStats()
    }

    /// Seals the open row so it becomes eligible for sync. `end` is clamped into
    /// [start, now] so a backdated idle or sleep boundary can never produce a
    /// negative or future duration.
    private func finalizeOpenSegment(at end: Date? = nil) {
        guard let id = openId, let start = openStart else { return }

        let proposed = end ?? openEnd ?? start
        let endTime = min(max(proposed, start), Date())
        let duration = Int(endTime.timeIntervalSince(start))

        do {
            if duration >= 1 {
                try DatabaseManager.shared.closeOpenActivity(
                    id: id, endTime: endTime, duration: duration
                )
                print("[DIAG] Sealed segment: \(openKey?.appName ?? "?"), duration: \(duration)s")
            } else {
                // Never accumulated a full second — drop it rather than sync noise.
                try DatabaseManager.shared.deleteActivity(id: id)
            }
        } catch {
            print("Failed to finalize activity: \(error)")
        }

        clearOpenSegment()
        refreshStats()
    }

    private func clearOpenSegment() {
        openId = nil
        openKey = nil
        openStart = nil
        openEnd = nil
        lastFlush = nil
    }

    private func currentIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    // MARK: - Capture Health

    /// Runs on the existing 60s diagnostic timer. Three independent signals,
    /// worst one wins:
    ///
    /// 1. Accessibility revoked — titles silently become nil forever. This was
    ///    only ever checked during onboarding, so a later TCC loss (cert
    ///    reissue, signature change, OS update) was invisible.
    /// 2. Browsers stuck in Automation backoff — URLs stop resolving quietly.
    /// 3. Coverage — seconds recorded vs. seconds the tracker has been running.
    ///    This is the signal that catches failures while permissions are
    ///    perfectly healthy, which is exactly what the title-change bug was.
    private func checkCaptureHealth() {
        guard isTracking else { return }

        if !AXIsProcessTrusted() {
            setHealth(.broken("Accessibility permission lost — window titles are no longer recorded"))
            return
        }

        let denied = browserURLTracker.deniedBrowserNames
        let urlHealth: CaptureHealth = denied.isEmpty
            ? .ok
            : .degraded("No URL access for \(denied.joined(separator: ", "))")

        guard let startedAt = trackingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)

        // Short windows are noisy — the open segment only reaches disk every
        // flushInterval — so don't judge coverage until there's enough of it.
        guard elapsed >= 300 else {
            setHealth(urlHealth)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let recorded = (try? DatabaseManager.shared.getRecordedSeconds(since: startedAt)) ?? 0
            let coverage = Double(recorded) / elapsed

            if coverage < 0.8 {
                self.setHealth(.broken(String(
                    format: "Only %.0f%% of the last %.0f min was recorded — time is being dropped",
                    coverage * 100, elapsed / 60
                )))
            } else {
                self.setHealth(urlHealth)
            }
        }
    }

    private func setHealth(_ health: CaptureHealth) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.captureHealth != health else { return }
            self.captureHealth = health
            if !health.isOK { print("[DIAG] Capture health: \(health.detail ?? "")") }
        }
    }

    // MARK: - Idle Handling

    /// Idle no longer stops recording — it changes what is recorded. The poll
    /// keeps running and tags rows `isIdle`, so the raw "what was in front"
    /// signal survives and the 300s threshold stays retunable against real data.
    /// Every existing query already filters `isIdle == false`, so reported
    /// totals are unaffected.
    private func handleIdleStateChange(isIdle: Bool) {
        print("[DIAG] Idle state changed: isIdle=\(isIdle) at \(Date())")

        if isIdle {
            // Idle began `idleTime` ago, not now. Seal the active segment at the
            // real boundary so the time spent away isn't billed as active use.
            let boundary = Date().addingTimeInterval(
                -min(currentIdleSeconds(), idleDetector.threshold)
            )
            finalizeOpenSegment(at: boundary)
            // The idle row starts at the boundary too, so the away time is
            // recorded as idle rather than left as a hole in the timeline.
            pollTick(backdatingStartTo: boundary)
            return
        }

        // Back from idle — open the active replacement immediately instead of
        // waiting up to a full interval for the next tick.
        pollTick()
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
