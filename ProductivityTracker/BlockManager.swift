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
            guard oldValue != isBlockingActive else { return }
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
    @Published var sudoersHelperInstalled: Bool = false

    private var workspaceCancellable: AnyCancellable?
    private var tempUnblockTimer: Timer?
    private var xpcConnection: NSXPCConnection?
    private var lastAppliedContentHash: String?

    private let helperMachServiceName = "com.rishabh.productivitytracker.helper"
    private let sudoersHelperPath = "/usr/local/bin/productivity-hosts-helper"
    private let sudoersFilePath = "/etc/sudoers.d/productivity-tracker"
    
    private init() {
        // Check helper status
        checkHelperStatus()
        checkSudoersHelper()

        // Update helper script if it's outdated (one-time password prompt)
        if sudoersHelperInstalled {
            if let installed = try? String(contentsOfFile: sudoersHelperPath, encoding: .utf8),
               installed.trimmingCharacters(in: .whitespacesAndNewlines) != helperScriptContent.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("[BlockManager] Helper script outdated, updating...")
                installSudoersHelper(force: true)
            }
        }

        // If XPC helper isn't available, try to install the sudoers helper (one-time password prompt)
        DispatchQueue.main.async {
            if !self.helperInstalled && !self.sudoersHelperInstalled {
                self.installSudoersHelper()
            }
        }

        // Delay state restoration and activation to the next runloop.
        // This prevents the synchronous AppleScript execution from pumping the runloop
        // while BlockManager.shared is still initializing, which causes an EXC_BREAKPOINT.
        DispatchQueue.main.async {
            self.isBlockingActive = UserDefaults.standard.bool(forKey: "isBlockingActive")
            // The didSet of isBlockingActive will automatically call activateBlocking() if true.
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
    
    // MARK: - Sudoers Helper

    private var helperScriptContent: String {
        """
        #!/bin/bash
        # ProductivityTracker hosts file manager
        # Installed once with admin privileges, runs silently via sudoers thereafter.

        MARKER_START="# ===== PRODUCTIVITYTRACKER-BLOCK-START ====="
        MARKER_END="# ===== PRODUCTIVITYTRACKER-BLOCK-END ====="
        HOSTS="/etc/hosts"
        ACTION="$1"
        BLOCK_FILE="$2"

        case "$ACTION" in
            apply)
                awk -v start="$MARKER_START" -v end="$MARKER_END" '
                    $0 == start { skip=1; next }
                    $0 == end { skip=0; next }
                    !skip { print }
                ' "$HOSTS" > "${HOSTS}.tmp"

                if [ -f "$BLOCK_FILE" ]; then
                    echo "" >> "${HOSTS}.tmp"
                    echo "$MARKER_START" >> "${HOSTS}.tmp"
                    cat "$BLOCK_FILE" >> "${HOSTS}.tmp"
                    echo "$MARKER_END" >> "${HOSTS}.tmp"
                fi

                mv "${HOSTS}.tmp" "$HOSTS"
                chmod 644 "$HOSTS"
                chown root:wheel "$HOSTS"

                /usr/bin/dscacheutil -flushcache 2>/dev/null
                /usr/bin/killall -HUP mDNSResponder 2>/dev/null
                ;;
            remove)
                awk -v start="$MARKER_START" -v end="$MARKER_END" '
                    $0 == start { skip=1; next }
                    $0 == end { skip=0; next }
                    !skip { print }
                ' "$HOSTS" > "${HOSTS}.tmp"
                mv "${HOSTS}.tmp" "$HOSTS"
                chmod 644 "$HOSTS"
                chown root:wheel "$HOSTS"
                /usr/bin/dscacheutil -flushcache 2>/dev/null
                /usr/bin/killall -HUP mDNSResponder 2>/dev/null
                ;;
            hash)
                awk -v start="$MARKER_START" -v end="$MARKER_END" '
                    $0 == start { printing=1 }
                    printing { print }
                    $0 == end { printing=0 }
                ' "$HOSTS" | /usr/bin/shasum -a 256 | cut -d' ' -f1
                ;;
            list)
                awk -v start="$MARKER_START" -v end="$MARKER_END" '
                    $0 == start { printing=1; next }
                    $0 == end { printing=0 }
                    printing && /^0\\.0\\.0\\.0 / { print $2 }
                ' "$HOSTS" | grep -v '^www\\.' | sort -u
                ;;
            *)
                echo "Usage: $0 {apply|remove|hash|list} [block_file]"
                exit 1
                ;;
        esac
        """
    }

    func installSudoersHelper(force: Bool = false) {
        if !force &&
           FileManager.default.fileExists(atPath: sudoersHelperPath) &&
           FileManager.default.fileExists(atPath: sudoersFilePath) {
            DispatchQueue.main.async { self.sudoersHelperInstalled = true }
            print("[BlockManager] Sudoers helper already installed")
            return
        }

        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("productivity-hosts-helper.sh")
        do {
            try helperScriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        } catch {
            print("[BlockManager] Failed to write temp helper script: \(error)")
            return
        }

        let username = NSUserName()

        let installCmd = [
            "cp '\(tempScript.path)' '\(sudoersHelperPath)'",
            "chmod 755 '\(sudoersHelperPath)'",
            "chown root:wheel '\(sudoersHelperPath)'",
            "echo '\(username) ALL=(root) NOPASSWD: \(sudoersHelperPath)' > '\(sudoersFilePath)'",
            "chmod 440 '\(sudoersFilePath)'",
            "visudo -c -f '\(sudoersFilePath)'",
            "rm -f '\(tempScript.path)'"
        ].joined(separator: " && ")

        let appleScriptCode = "do shell script \"\(installCmd)\" with administrator privileges"

        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: appleScriptCode) {
            let _ = script.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                DispatchQueue.main.async { self.sudoersHelperInstalled = true }
                print("[BlockManager] Sudoers helper installed — no more password prompts!")
            } else {
                print("[BlockManager] Failed to install sudoers helper: \(String(describing: errorInfo))")
                print("[BlockManager] Will continue using AppleScript fallback")
            }
        }
    }

    func checkSudoersHelper() {
        sudoersHelperInstalled = FileManager.default.fileExists(atPath: sudoersHelperPath)
            && FileManager.default.fileExists(atPath: sudoersFilePath)
    }

    private func updateHostsViaSudoers(domains: [String], block: Bool) -> Bool {
        if block && !domains.isEmpty {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("productivity-blocklist.txt")
            var content = ""
            for domain in domains {
                let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                guard !clean.isEmpty else { continue }
                content += "0.0.0.0 \(clean)\n"
                content += "0.0.0.0 www.\(clean)\n"
                content += "::1 \(clean)\n"
                content += "::1 www.\(clean)\n"
            }
            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                print("[BlockManager] Failed to write temp blocklist: \(error)")
                return false
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [sudoersHelperPath, "apply", tempFile.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: tempFile)
                return process.terminationStatus == 0
            } catch {
                print("[BlockManager] Sudoers helper execution failed: \(error)")
                return false
            }
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [sudoersHelperPath, "remove"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                print("[BlockManager] Sudoers helper execution failed: \(error)")
                return false
            }
        }
    }

    private func getHostsHashViaSudoers() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [sudoersHelperPath, "hash"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let hash = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (hash?.isEmpty == false) ? hash : nil
        } catch {
            return nil
        }
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

        // Tier 1: XPC helper (only works with paid Apple Developer Program)
        if helperInstalled, let proxy = getHelperProxy() {
            proxy.updateBlockedDomains(domains) { success, error in
                if success {
                    print("[BlockManager] Applied \(domains.count) domains via XPC helper")
                    TamperMonitor.shared.updateExpectedHash()
                } else {
                    print("[BlockManager] XPC failed: \(error ?? "unknown"). Trying sudoers helper.")
                    if self.sudoersHelperInstalled {
                        let ok = self.updateHostsViaSudoers(domains: domains, block: true)
                        if ok {
                            print("[BlockManager] Applied \(domains.count) domains via sudoers helper (silent)")
                            TamperMonitor.shared.updateExpectedHash()
                        } else {
                            print("[BlockManager] Sudoers failed. Falling back to AppleScript.")
                            self.updateHostsViaAppleScript(domains: domains, block: true)
                        }
                    } else {
                        self.updateHostsViaAppleScript(domains: domains, block: true)
                    }
                }
            }
            return
        }

        // Tier 2: Sudoers helper (silent, no password)
        if sudoersHelperInstalled {
            let ok = updateHostsViaSudoers(domains: domains, block: true)
            if ok {
                print("[BlockManager] Applied \(domains.count) domains via sudoers helper (silent)")
                TamperMonitor.shared.updateExpectedHash()
                return
            }
            print("[BlockManager] Sudoers helper failed, falling back to AppleScript")
        }

        // Tier 3: AppleScript (shows password dialog)
        updateHostsViaAppleScript(domains: domains, block: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TamperMonitor.shared.updateExpectedHash() }
    }

    func applyBlockListIfChanged() {
        guard isBlockingActive else { return }

        let domains: [String]
        do {
            domains = try DatabaseManager.shared.getActiveBlockedDomains()
        } catch {
            print("[BlockManager] Failed to read blocked domains: \(error)")
            return
        }

        // Compute hash of the domain list content
        let content = domains.sorted().joined(separator: "\n")
        var hasher = Hasher()
        hasher.combine(content)
        let newHash = String(hasher.finalize())

        if newHash == lastAppliedContentHash {
            print("[BlockManager] Block list unchanged (\(domains.count) domains), skipping write")
            return
        }

        applyBlockList()
        lastAppliedContentHash = newHash
    }

    func getHostsHash(completion: @escaping (String) -> Void) {
        // Tier 1: XPC
        if helperInstalled, let proxy = getHelperProxy() {
            proxy.getHostsFileHash { hash in
                completion(hash)
            }
            return
        }

        // Tier 2: Sudoers helper (this makes TamperMonitor work again!)
        if sudoersHelperInstalled, let hash = getHostsHashViaSudoers() {
            completion(hash)
            return
        }

        // Tier 3: No way to read hash without privileges
        completion("unavailable")
    }

    func getBlockedDomainsFromHosts(completion: @escaping ([String]) -> Void) {
        guard sudoersHelperInstalled else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [self.sudoersHelperPath, "list"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let domains = output
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                completion(domains)
            } catch {
                print("[BlockManager] Failed to list hosts domains: \(error)")
                completion([])
            }
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

        // Tier 1: XPC
        if helperInstalled, let proxy = getHelperProxy() {
            proxy.removeAllBlocks { success in
                if success {
                    print("[BlockManager] Removed all blocks via XPC helper")
                    TamperMonitor.shared.updateExpectedHash()
                    proxy.flushDNS { _ in }
                }
            }
            return
        }

        // Tier 2: Sudoers helper
        if sudoersHelperInstalled {
            let ok = updateHostsViaSudoers(domains: [], block: false)
            if ok {
                print("[BlockManager] Removed all blocks via sudoers helper (silent)")
                TamperMonitor.shared.updateExpectedHash()
                return
            }
        }

        // Tier 3: AppleScript
        updateHostsViaAppleScript(domains: [], block: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TamperMonitor.shared.updateExpectedHash() }
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
