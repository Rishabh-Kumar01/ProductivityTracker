//
//  BlockManager.swift
//  ProductivityTracker
//
//  Created by Rishabh on 23/03/26.
//

import AppKit
import Foundation
import Combine

// MARK: - Block Manager

class BlockManager: ObservableObject {
    static let shared = BlockManager()
    
    @Published var isBlockingActive: Bool = false {
        didSet {
            UserDefaults.standard.set(isBlockingActive, forKey: "isBlockingActive")
            if isBlockingActive {
                activateBlocking()
            } else {
                deactivateBlocking()
            }
        }
    }
    
    // Configurable blocked apps (bundle IDs)
    @Published var blockedBundleIds: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.TV"
    ]
    
    private var workspaceCancellable: AnyCancellable?
    private var tempUnblockTimer: Timer?
    
    private init() {
        self.isBlockingActive = UserDefaults.standard.bool(forKey: "isBlockingActive")
        if self.isBlockingActive {
            self.activateBlocking()
        }
        
        // Start temp unblock check timer
        tempUnblockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkExpiredUnblocks()
        }
    }
    
    private func checkExpiredUnblocks() {
        guard isBlockingActive else { return }
        do {
            let didClear = try DatabaseManager.shared.clearExpiredTempUnblocks()
            if didClear {
                print("[BlockManager] Temporary unblocks expired. Reapplying blocklist.")
                applyBlockList()
            }
        } catch {
            print("[BlockManager] Failed to clear expired unblocks: \(error)")
        }
    }
    
    // MARK: - API
    
    func applyBlockList() {
        if isBlockingActive {
            updateHostsFile(block: true)
        }
    }
    
    // MARK: - Activation / Deactivation
    
    private func activateBlocking() {
        // 1. Force terminate any currently running blocked apps
        terminateBlockedApps()
        
        // 2. Observe future app launches
        workspaceCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                
                if let bundleId = app.bundleIdentifier, self.blockedBundleIds.contains(bundleId) {
                    print("Blocked app launched, terminating: " + bundleId)
                    app.forceTerminate()
                }
            }
        
        // 3. Block websites via /etc/hosts
        updateHostsFile(block: true)
    }
    
    private func deactivateBlocking() {
        workspaceCancellable?.cancel()
        workspaceCancellable = nil
        
        // Unblock websites
        updateHostsFile(block: false)
    }
    
    // MARK: - App Blocking
    
    private func terminateBlockedApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let bundleId = app.bundleIdentifier, blockedBundleIds.contains(bundleId) {
                print("Terminating running blocked app: " + bundleId)
                app.forceTerminate()
            }
        }
    }
    
    // MARK: - Website Blocking (/etc/hosts)
    
    private func updateHostsFile(block: Bool) {
        let markerPrefix = "# ===== PRODUCTIVITYTRACKER-BLOCK-START ====="
        let markerSuffix = "# ===== PRODUCTIVITYTRACKER-BLOCK-END ====="
        
        var shellScript = ""
        
        if block {
            let domains: [String]
            do {
                domains = try DatabaseManager.shared.getActiveBlockedDomains()
            } catch {
                print("Failed to read blocked domains: \(error)")
                domains = []
            }
            
            var hostsContent = "\n" + markerPrefix + "\n"
            for site in domains {
                // Ensure no malformed newlines or quotes in domain
                let cleanSite = site.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                if cleanSite.isEmpty { continue }
                
                hostsContent += "0.0.0.0 " + cleanSite + "\n"
                hostsContent += "0.0.0.0 www." + cleanSite + "\n"
                hostsContent += "::1 " + cleanSite + "\n"
                hostsContent += "::1 www." + cleanSite + "\n"
            }
            hostsContent += markerSuffix + "\n"
            
            shellScript = """
            #!/bin/sh
            sed -i '' '/\(markerPrefix)/,/\(markerSuffix)/d' /etc/hosts
            echo "\(hostsContent)" >> /etc/hosts
            dscacheutil -flushcache
            killall -HUP mDNSResponder
            """
        } else {
            shellScript = """
            #!/bin/sh
            sed -i '' '/\(markerPrefix)/,/\(markerSuffix)/d' /etc/hosts
            dscacheutil -flushcache
            killall -HUP mDNSResponder
            """
        }
        
        // Write the script to a temporary file
        let tempScriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("pt_hosts.sh")
        do {
            try shellScript.write(to: tempScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptURL.path)
            
            // Execute the script via privileged AppleScript
            let appleScriptCode = """
            do shell script "\(tempScriptURL.path)" with administrator privileges
            """
            
            var errorInfo: NSDictionary?
            if let script = NSAppleScript(source: appleScriptCode) {
                let _ = script.executeAndReturnError(&errorInfo)
                if let errorDesc = errorInfo {
                    print("Hosts file modification error: \(errorDesc)")
                } else {
                    print("Hosts file updated successfully. Block: " + String(block))
                }
            }
        } catch {
            print("Failed to write temporary script: \\(error)")
        }
    }
}
