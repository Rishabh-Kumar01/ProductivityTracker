//
//  IdleDetector.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import Foundation
import Combine
import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let idleStateChanged = Notification.Name("idleStateChanged")
}

// MARK: - Idle Detector

class IdleDetector: ObservableObject {
    @Published var isIdle = false
    let threshold: TimeInterval
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?

    init(threshold: TimeInterval = 300) {
        self.threshold = threshold
    }

    func start() {
        // Poll every 5 seconds with 1s tolerance for coalescing
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 1.0

        // Detect sleep
        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setIdle(true)
        }
        workspaceObservers.append(sleepObserver)

        // Detect wake
        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.check()
        }
        workspaceObservers.append(wakeObserver)

        // Detect screen lock
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setIdle(true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            distributedObserver = nil
        }
    }

    private func check() {
        let idleTime = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        let nowIdle = idleTime >= threshold
        if nowIdle != isIdle {
            setIdle(nowIdle)
        }
    }

    private func setIdle(_ idle: Bool) {
        let wasIdle = isIdle
        isIdle = idle
        if wasIdle != idle {
            NotificationCenter.default.post(
                name: .idleStateChanged,
                object: nil,
                userInfo: ["isIdle": idle]
            )
        }
    }

    deinit {
        stop()
    }
}
