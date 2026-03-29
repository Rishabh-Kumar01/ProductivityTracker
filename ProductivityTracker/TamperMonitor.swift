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
        // 1. Re-apply the block list
        BlockManager.shared.applyBlockList()
        
        // 2. Wait a moment then update Expected Hash (since we just rewrote it)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.updateExpectedHash()
        }
        
        // 3. Inform Backend
        guard let url = URL(string: "\(APIConfig.baseURL)/accountability/tamper-event") else { return }
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[TamperMonitor] Failed to report tamper event: \(error)")
            } else {
                print("[TamperMonitor] Successfully reported tamper event to server")
            }
        }.resume()
    }
}
