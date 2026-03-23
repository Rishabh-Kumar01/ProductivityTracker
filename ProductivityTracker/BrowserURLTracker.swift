//
//  BrowserURLTracker.swift
//  ProductivityTracker
//
//  Created by Rishabh on 20/03/26.
//

import Foundation
import AppKit

// MARK: - Browser URL Tracker

class BrowserURLTracker {

    // Bundle IDs → AppleScript commands for each supported browser
    private let browserScripts: [String: String] = [
        "com.apple.Safari": """
            tell application "Safari" to return URL of current tab of front window
            """,
        "com.google.Chrome": """
            tell application "Google Chrome" to return URL of active tab of front window
            """,
        "company.thebrowser.Browser": """
            tell application "Arc" to return URL of active tab of front window
            """,
        "com.brave.Browser": """
            using terms from application "Google Chrome"
                tell application "Brave Browser" to return URL of active tab of front window
            end using terms from
            """,
        "com.microsoft.edgemac": """
            using terms from application "Google Chrome"
                tell application "Microsoft Edge" to return URL of active tab of front window
            end using terms from
            """
    ]

    // Human-friendly browser names for notifications
    private let browserNames: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge"
    ]

    // Retry-with-backoff: track denied browsers with retry timestamps
    private struct DeniedState {
        var retryAfter: Date
        var backoffSeconds: TimeInterval  // starts at 60, doubles to max 300
    }
    private var deniedBrowsers: [String: DeniedState] = [:]

    // Track whether we've already shown the permission prompt to the user
    private var hasShownPermissionPrompt = false

    /// Set of all known browser bundle IDs
    var knownBrowserBundleIds: Set<String> {
        Set(browserScripts.keys)
    }

    /// Check if a given bundle ID is a known browser
    func isBrowser(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return browserScripts.keys.contains(bundleId)
    }

    /// Reset a browser's denied status (call when user says they've fixed permissions)
    func resetDeniedStatus() {
        deniedBrowsers.removeAll()
        hasShownPermissionPrompt = false
        print("[URLTracker] Reset all denied browser statuses — will retry on next poll")
    }

    /// Run a startup diagnostic: test AppleScript for each running browser
    func runStartupDiagnostic() {
        let runningApps = NSWorkspace.shared.runningApplications
        for (bundleId, _) in browserScripts {
            let name = browserNames[bundleId] ?? bundleId
            let isRunning = runningApps.contains { $0.bundleIdentifier == bundleId }
            guard isRunning else { continue }

            let url = getURL(forBundleId: bundleId)
            if url != nil {
                print("[URLTracker] \(name): ✓ URL access granted")
            } else if deniedBrowsers[bundleId] != nil {
                print("[URLTracker] \(name): ✗ denied — will retry in 60s")
            }
        }
    }

    /// Get the current URL from the frontmost browser tab
    func getURL(forBundleId bundleId: String) -> String? {
        guard let scriptSource = browserScripts[bundleId] else { return nil }

        // Check retry-with-backoff: skip if denied and not yet time to retry
        if let denied = deniedBrowsers[bundleId] {
            if Date() < denied.retryAfter {
                return nil  // Still in backoff period — skip silently
            }
            // Time to retry — remove from denied and try again
        }

        // Verify the browser is actually running before executing AppleScript
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleId
        }
        guard isRunning else { return nil }

        guard let appleScript = NSAppleScript(source: scriptSource) else { return nil }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            if errorNumber == -1743 {
                // Automation permission denied — use exponential backoff
                let name = browserNames[bundleId] ?? bundleId
                let currentBackoff = deniedBrowsers[bundleId]?.backoffSeconds ?? 30
                let nextBackoff = min(currentBackoff * 2, 300)  // max 5 minutes
                deniedBrowsers[bundleId] = DeniedState(
                    retryAfter: Date().addingTimeInterval(nextBackoff),
                    backoffSeconds: nextBackoff
                )
                print("[URLTracker] ⚠️ Automation denied for \(name). Will retry in \(Int(nextBackoff))s.")

                // Show ONE system prompt to guide the user
                if !hasShownPermissionPrompt {
                    hasShownPermissionPrompt = true
                    showAutomationPermissionAlert()
                }
            } else if errorNumber == -600 {
                // App not running — normal condition, silence it
            } else if errorNumber == -1728 {
                // No windows open — normal, don't log
            } else {
                print("[URLTracker] AppleScript error for \(bundleId): \(error)")
            }
            return nil
        }

        // SUCCESS — if this browser was previously denied, clear it
        if deniedBrowsers.removeValue(forKey: bundleId) != nil {
            let name = browserNames[bundleId] ?? bundleId
            print("[URLTracker] ✓ \(name) permission granted — URL tracking resumed")
        }

        return result.stringValue
    }

    /// Extract the domain from a URL string (e.g., "https://www.github.com/foo" → "github.com")
    static func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host else { return nil }
        // Strip "www." prefix
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    // MARK: - Permission Prompt

    private func showAutomationPermissionAlert() {
        DispatchQueue.main.async {
            // Activate our app to foreground (required for LSUIElement apps with no Dock icon)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Browser URL Tracking Needs Permission"
            alert.informativeText = "ProductivityTracker needs Automation permission to track which websites you visit.\n\nAfter clicking \"Open System Settings\", find ProductivityTracker and toggle ON each browser (Brave, Edge, Chrome, Safari).\n\nThen relaunch ProductivityTracker."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
