//
//  TamperMonitor.swift
//  ProductivityTracker
//

import Foundation
import Combine

class TamperMonitor: ObservableObject {
    static let shared = TamperMonitor()

    private var timer: Timer?
    private var expectedHash: String?
    private var consecutiveCleanChecks = 0
    private var currentInterval: TimeInterval = 60

    private init() {}

    func start() {
        guard timer == nil else { return }

        updateExpectedHash()
        currentInterval = 60
        consecutiveCleanChecks = 0
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.checkIntegrity()
        }
        timer?.tolerance = 10
        print("[TamperMonitor] Started with \(Int(currentInterval))s interval")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        expectedHash = nil
        consecutiveCleanChecks = 0
        print("[TamperMonitor] Stopped")
    }

    func updateExpectedHash() {
        BlockManager.shared.getHostsHash { [weak self] hash in
            self?.expectedHash = hash
            print("[TamperMonitor] Expected hash set to: \(hash)")
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.checkIntegrity()
        }
        timer?.tolerance = 10
    }

    private func checkIntegrity() {
        guard AccountabilityManager.shared.isAccountabilityActive else {
            stop()
            return
        }

        BlockManager.shared.getHostsHash { [weak self] currentHash in
            guard let self = self, let expected = self.expectedHash else { return }

            if currentHash != expected && expected != "unavailable" && currentHash != "unavailable" {
                // TAMPER DETECTED
                self.consecutiveCleanChecks = 0
                if self.currentInterval != 60 {
                    self.currentInterval = 60
                    self.restartTimer()
                    print("[TamperMonitor] Tampering detected — checking every 60s")
                }
                print("[TamperMonitor] hosts file was manually modified! Expected: \(expected), Got: \(currentHash)")
                self.handleTampering()
            } else if currentHash != "unavailable" {
                // Clean check
                self.consecutiveCleanChecks += 1
                if self.consecutiveCleanChecks >= 10 && self.currentInterval < 300 {
                    self.currentInterval = 300
                    self.restartTimer()
                    print("[TamperMonitor] No tampering for 10 checks — slowing to 5-min interval")
                }
            }
        }
    }
    
    private func handleTampering() {
        // 1. Read current hosts file domains BEFORE re-applying
        BlockManager.shared.getBlockedDomainsFromHosts { [weak self] currentHostsDomains in
            guard let self = self else { return }

            // 2. Get expected domains from local SQLite
            var expectedDomains: [String] = []
            do {
                expectedDomains = try DatabaseManager.shared.getActiveBlockedDomains()
            } catch {
                print("[TamperMonitor] Failed to read expected domains: \(error)")
            }

            // 3. Compute diff
            let currentSet = Set(currentHostsDomains.map { $0.lowercased() })
            let expectedSet = Set(expectedDomains.map { $0.lowercased() })

            let removedFromHosts = expectedSet.subtracting(currentSet)  // should be blocked but aren't
            let addedToHosts = currentSet.subtracting(expectedSet)      // in hosts but shouldn't be

            let removedArray = Array(removedFromHosts.prefix(100))
            let addedArray = Array(addedToHosts.prefix(100))

            print("[TamperMonitor] Diff — removed: \(removedFromHosts.count), added: \(addedToHosts.count)")
            if !removedArray.isEmpty {
                print("[TamperMonitor] Removed domains (sample): \(removedArray.prefix(5))")
            }
            if !addedArray.isEmpty {
                print("[TamperMonitor] Added domains (sample): \(addedArray.prefix(5))")
            }

            // 4. Re-apply the block list (this also updates expectedHash via Part 1 fix)
            BlockManager.shared.applyBlockList()

            // 5. Update expected hash after re-apply settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.updateExpectedHash()
            }

            // 6. Report to backend with diff
            self.reportTamperEvent(
                removedDomains: removedArray,
                addedDomains: addedArray,
                removedCount: removedFromHosts.count,
                addedCount: addedToHosts.count
            )
        }
    }

    private func reportTamperEvent(removedDomains: [String], addedDomains: [String], removedCount: Int, addedCount: Int) {
        guard let url = URL(string: "\(APIConfig.baseURL)/accountability/tamper-event") else { return }
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "removedDomains": removedDomains,
            "addedDomains": addedDomains,
            "removedCount": removedCount,
            "addedCount": addedCount
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[TamperMonitor] Failed to report tamper event: \(error)")
            } else {
                print("[TamperMonitor] Successfully reported tamper event (removed: \(removedCount), added: \(addedCount))")
            }
        }.resume()
    }
}
