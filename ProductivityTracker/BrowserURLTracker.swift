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

    // Track which browsers have denied automation permission so we don't spam logs
    private var deniedBrowsers: Set<String> = []

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

    /// Get the current URL from the frontmost browser tab
    func getURL(forBundleId bundleId: String) -> String? {
        guard let scriptSource = browserScripts[bundleId] else { return nil }

        // Skip browsers where we already know automation is denied
        if deniedBrowsers.contains(bundleId) {
            return nil
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
                // Automation permission denied — cache it so we don't retry every 2s
                let name = browserNames[bundleId] ?? bundleId
                deniedBrowsers.insert(bundleId)
                print("[URLTracker] ⚠️ Automation permission denied for \(name). URL tracking disabled for this browser until permission is granted.")

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
