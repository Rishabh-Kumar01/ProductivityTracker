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

    /// Set of all known browser bundle IDs
    var knownBrowserBundleIds: Set<String> {
        Set(browserScripts.keys)
    }

    /// Check if a given bundle ID is a known browser
    func isBrowser(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return browserScripts.keys.contains(bundleId)
    }

    /// Get the current URL from the frontmost browser tab
    func getURL(forBundleId bundleId: String) -> String? {
        print("getURL called for bundleId: \(bundleId)")
        guard let scriptSource = browserScripts[bundleId] else { return nil }

        // Verify the browser is actually running before executing AppleScript
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleId
        }
        print("isRunning check for \(bundleId): \(isRunning)")
        guard isRunning else { return nil }

        print("Executing AppleScript for \(bundleId)")
        guard let appleScript = NSAppleScript(source: scriptSource) else { return nil }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            if errorNumber == -1743 {
                // Automation permission denied — user needs to allow in System Settings
                print("Automation permission denied for bundle: \(bundleId). Guide user to System Settings > Privacy > Automation.")
            } else if errorNumber == -600 {
                // App not running — normal condition, silence it
            } else {
                print("AppleScript error for \(bundleId): \(error)")
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
}
