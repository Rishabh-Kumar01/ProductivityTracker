//
//  BlocklistSyncManager.swift
//  ProductivityTracker
//

import Foundation
import Combine

class BlocklistSyncManager: ObservableObject {
    static let shared = BlocklistSyncManager()
    
    @Published var lastSyncStatus: String = "Not synced"
    @Published var isSyncing: Bool = false
    
    private var timer: Timer?
    private let apiBaseURL = APIConfig.baseURL
    
    private init() {}
    
    func start() {
        // Sync immediately on launch
        syncNow()
        
        // Sync every 10 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.syncNow()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func syncNow() {
        guard AuthManager.shared.isLoggedIn else {
            DispatchQueue.main.async { self.lastSyncStatus = "Not logged in" }
            return
        }
        
        guard !isSyncing else { return }
        DispatchQueue.main.async { self.isSyncing = true }
        
        // Fetch all blocked domains in one go using large limit
        guard let url = URL(string: "\(apiBaseURL)/blocker/domains?limit=500000") else { return }
        
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer {
                DispatchQueue.main.async { self?.isSyncing = false }
            }
            
            if let error = error {
                print("[BlocklistSyncManager] Sync failed: \(error)")
                DispatchQueue.main.async { self?.lastSyncStatus = "Error: \(error.localizedDescription)" }
                return
            }
            
            guard let data = data else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let dataObj = json["data"] as? [String: Any],
                   let domainsList = dataObj["domains"] as? [[String: Any]] {
                    
                    var newRecords: [BlockedDomain] = []
                    
                    for item in domainsList {
                        if let domain = item["domain"] as? String,
                           let source = item["source"] as? String,
                           let id = item["id"] as? String {
                            
                            var tempUntil: Date? = nil
                            if let tempStr = item["temp_unblock_until"] as? String {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                tempUntil = formatter.date(from: tempStr)
                                if tempUntil == nil {
                                    // fallback without fractional
                                    let formatter2 = ISO8601DateFormatter()
                                    tempUntil = formatter2.date(from: tempStr)
                                }
                            }
                            
                            var createdAt: Date? = nil
                            if let createdStr = item["created_at"] as? String {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                createdAt = formatter.date(from: createdStr)
                                if createdAt == nil {
                                    let formatter2 = ISO8601DateFormatter()
                                    createdAt = formatter2.date(from: createdStr)
                                }
                            }
                            
                            newRecords.append(BlockedDomain(
                                id: id,
                                domain: domain,
                                source: source,
                                tempUnblockUntil: tempUntil,
                                addedAt: createdAt
                            ))
                        }
                    }
                    
                    try DatabaseManager.shared.replaceBlockedDomains(newRecords)
                    
                    // After updating database, apply blocks only if content changed
                    BlockManager.shared.applyBlockListIfChanged()
                    
                    let now = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                    DispatchQueue.main.async {
                        self?.lastSyncStatus = "Synced at \(now) (\(newRecords.count) domains)"
                        print("[BlocklistSyncManager] Successfully synced \(newRecords.count) domains")
                    }
                }
            } catch {
                print("[BlocklistSyncManager] Parse/DB error: \(error)")
                DispatchQueue.main.async { self?.lastSyncStatus = "Parse Error" }
            }
        }.resume()
    }
}
