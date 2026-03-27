//
//  BlockManager.swift
//  ProductivityTracker
//
//  Created by Rishabh on 23/03/26.
//

import AppKit
import Foundation
import Combine
import ServiceManagement

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
    
    @Published var helperInstalled: Bool = false
    
    private var workspaceCancellable: AnyCancellable?
    private var tempUnblockTimer: Timer?
    private var xpcConnection: NSXPCConnection?
    
    private let helperMachServiceName = "com.rishabh.productivitytracker.helper"
    
    private init() {
        self.isBlockingActive = UserDefaults.standard.bool(forKey: "isBlockingActive")
        
        // Check helper status
        checkHelperStatus()
        
        if self.isBlockingActive {
            self.activateBlocking()
        }
        
        // Start temp unblock check timer
        tempUnblockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkExpiredUnblocks()
        }
    }
    
    // MARK: - Helper Installation
    
    func installHelper() {
        let daemon = SMAppService.daemon(plistName: "com.rishabh.productivitytracker.helper.plist")
        do {
            try daemon.register()
            DispatchQueue.main.async {
                self.helperInstalled = true
            }
            print("[BlockManager] Helper daemon registered successfully")
        } catch {
            print("[BlockManager] Failed to register helper daemon: \(error)")
            print("[BlockManager] Falling back to AppleScript approach")
        }
    }
    
    func checkHelperStatus() {
        let daemon = SMAppService.daemon(plistName: "com.rishabh.productivitytracker.helper.plist")
        DispatchQueue.main.async {
            self.helperInstalled = (daemon.status == .enabled)
        }
    }
    
    // MARK: - XPC Connection
    
    private func getHelperProxy() -> HostsHelperProtocol? {
        if xpcConnection == nil {
            let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)
            
            connection.invalidationHandler = { [weak self] in
                self?.xpcConnection = nil
                print("[BlockManager] XPC connection invalidated")
            }
            connection.interruptionHandler = { [weak self] in
                self?.xpcConnection = nil
                print("[BlockManager] XPC connection interrupted")
            }
            
            connection.resume()
            xpcConnection = connection
        }
        
        return xpcConnection?.remoteObjectProxyWithErrorHandler { error in
            print("[BlockManager] XPC proxy error: \(error)")
        } as? HostsHelperProtocol
    }
    
    // MARK: - API
    
    func applyBlockList() {
        guard isBlockingActive else { return }
        
        let domains: [String]
        do {
            domains = try DatabaseManager.shared.getActiveBlockedDomains()
        } catch {
            print("[BlockManager] Failed to read blocked domains: \(error)")
            return
        }
        
        guard !domains.isEmpty else {
            print("[BlockManager] No domains to block")
            return
        }
        
        // Try XPC first, fall back to AppleScript
        if helperInstalled, let proxy = getHelperProxy() {
            proxy.updateBlockedDomains(domains) { success, error in
                if success {
                    print("[BlockManager] Applied \(domains.count) domains via XPC helper")
                } else {
                    print("[BlockManager] XPC helper failed: \(error ?? "unknown"). Falling back to AppleScript.")
                    self.updateHostsViaAppleScript(domains: domains, block: true)
                }
            }
        } else {
            updateHostsViaAppleScript(domains: domains, block: true)
        }
    }
    
    func getHostsHash(completion: @escaping (String) -> Void) {
        if let proxy = getHelperProxy() {
            proxy.getHostsFileHash { hash in
                completion(hash)
            }
        } else {
            completion("unavailable")
        }
    }
    
    // MARK: - Temp Unblock Timer
    
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
        
        // 3. Block websites
        applyBlockList()
    }
    
    private func deactivateBlocking() {
        workspaceCancellable?.cancel()
        workspaceCancellable = nil
        
        // Unblock websites
        if helperInstalled, let proxy = getHelperProxy() {
            proxy.removeAllBlocks { success in
                if success {
                    print("[BlockManager] Removed all blocks via XPC helper")
                    proxy.flushDNS { _ in }
                }
            }
        } else {
            updateHostsViaAppleScript(domains: [], block: false)
        }
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
    
    // MARK: - AppleScript Fallback (used when helper is not installed)
    
    private func updateHostsViaAppleScript(domains: [String], block: Bool) {
        let markerPrefix = "# ===== PRODUCTIVITYTRACKER-BLOCK-START ====="
        let markerSuffix = "# ===== PRODUCTIVITYTRACKER-BLOCK-END ====="
        
        var shellScript = ""
        
        if block && !domains.isEmpty {
            var hostsContent = "\n" + markerPrefix + "\n"
            for site in domains {
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
                    print("Hosts file updated successfully (AppleScript fallback). Block: " + String(block))
                }
            }
        } catch {
            print("Failed to write temporary script: \(error)")
        }
    }
}
