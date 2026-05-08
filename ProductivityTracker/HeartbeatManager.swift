//
//  HeartbeatManager.swift
//  ProductivityTracker
//

import Foundation

class HeartbeatManager {
    static let shared = HeartbeatManager()
    
    private var timer: Timer?
    private let apiBaseURL = APIConfig.baseURL
    
    private init() {}
    
    func start() {
        guard timer == nil else { return }
        
        sendHeartbeat()
        
        // Send every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
        timer?.tolerance = 30
        print("[HeartbeatManager] Started")
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        print("[HeartbeatManager] Stopped")
    }
    
    func sendHeartbeat(isTerminating: Bool = false) {
        guard AuthManager.shared.isLoggedIn else { return }
        guard let url = URL(string: "\(apiBaseURL)/heartbeat") else { return }
        
        let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let isBlockingActive = BlockManager.shared.isBlockingActive
        
        // Get active blocked domains count
        var count = 0
        do {
            count = try DatabaseManager.shared.getActiveBlockedDomains().count
        } catch {
            print("[HeartbeatManager] Database error reading domain count")
        }
        
        let body: [String: Any] = [
            "clientVersion": clientVersion,
            // Server upserts heartbeats by (user_id, platform) since the cross-
            // platform schema migration. Tag explicitly so we never collide with
            // the Android client's row.
            "platform": "macos",
            "isBlockingActive": isBlockingActive,
            "blockedDomainCount": count,
            "terminating": isTerminating,
            // Mac's current TZ (IANA id, e.g. "Asia/Kolkata"). Server keeps
            // users.timezone in sync from this — moving across TZs (travel,
            // DST) self-corrects the dashboard's daily/hourly bucketing on
            // the next 5-min tick.
            "timezone": TimeZone.current.identifier
        ]
        
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let bodyData = try? JSONSerialization.data(withJSONObject: body) {
            request.httpBody = bodyData
        }
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[HeartbeatManager] Failed to send heartbeat: \(error)")
            } else if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 201 {
                // Silent success
            }
        }
        
        if isTerminating {
            // Wait briefly to send the request before terminating
            let semaphore = DispatchSemaphore(value: 0)
            let termTask = URLSession.shared.dataTask(with: request) { _, _, _ in
                semaphore.signal()
            }
            termTask.resume()
            _ = semaphore.wait(timeout: .now() + 1.0)
        } else {
            task.resume()
        }
    }
}
