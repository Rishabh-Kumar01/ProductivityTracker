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
    
    private init() {}
    
    func start() {
        guard timer == nil else { return }
        
        // Initial expected hash immediately
        updateExpectedHash()
        
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIntegrity()
        }
        timer?.tolerance = 10
        print("[TamperMonitor] Started")
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        expectedHash = nil
        print("[TamperMonitor] Stopped")
    }
    
    func updateExpectedHash() {
        BlockManager.shared.getHostsHash { [weak self] hash in
            self?.expectedHash = hash
            print("[TamperMonitor] Expected hash set to: \(hash)")
        }
    }
    
    private func checkIntegrity() {
        guard AccountabilityManager.shared.isAccountabilityActive else {
            stop()
            return
        }
        
        BlockManager.shared.getHostsHash { [weak self] currentHash in
            guard let self = self, let expected = self.expectedHash else { return }
            
            if currentHash != expected && expected != "unavailable" && currentHash != "unavailable" {
                print("[TamperMonitor] ⚠️ hosts file was manually modified! Expected: \(expected), Got: \(currentHash)")
                self.handleTampering()
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
        guard let url = URL(string: "http://localhost:3000/api/accountability/tamper-event") else { return }
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
