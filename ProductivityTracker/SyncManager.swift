//
//  SyncManager.swift
//  ProductivityTracker
//
//  Created by Rishabh on 23/03/26.
//

import Foundation

// MARK: - Sync Manager

class SyncManager {
    static let shared = SyncManager()

    private var syncTimer: Timer?
    private let baseURL = "http://localhost:3000/api"

    private init() {}

    func startSync() {
        guard syncTimer == nil else { return }
        // Sync every 10 seconds for testing
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            self?.performSync()
        }
        syncTimer?.tolerance = 2

        // Perform an initial sync immediately
        performSync()
    }

    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func performSync() {
        guard AuthManager.shared.isLoggedIn else { return }

        Task {
            do {
                // 1. Fetch unsynced records (WHERE isSynced=false AND isSyncing=false)
                let records = try DatabaseManager.shared.getUnsyncedActivities(limit: 100)
                guard !records.isEmpty else { return }

                let ids = records.map { $0.id }
                
                // 2. Atomically mark as syncing BEFORE the POST
                //    This prevents the next sync cycle from re-fetching these records
                try DatabaseManager.shared.markAsSyncing(ids: ids)
                
                print("[Sync] Found \(records.count) unsynced activities, uploading...")

                // 3. Convert to JSON payload
                let activities = records.map { record -> [String: Any] in
                    var dict: [String: Any] = [
                        "appName": record.appName,
                        "startTime": ISO8601DateFormatter().string(from: record.startTime),
                        "endTime": ISO8601DateFormatter().string(from: record.endTime),
                        "category": record.category,
                        "productivityScore": record.productivityScore,
                        "isIdle": record.isIdle,
                    ]
                    if let bundleId = record.bundleId { dict["bundleId"] = bundleId }
                    if let windowTitle = record.windowTitle { dict["windowTitle"] = windowTitle }
                    if let url = record.url { dict["url"] = url }
                    return dict
                }

                let payload: [String: Any] = ["activities": activities]

                // 4. POST to server
                let url = URL(string: "\(baseURL)/activities/bulk")!
                var request = AuthManager.shared.authenticatedRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                request.timeoutInterval = 30

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    try DatabaseManager.shared.markAsSyncFailed(ids: ids)
                    return
                }
                
                print("[Sync] Server responded with status: \(httpResponse.statusCode)")

                if httpResponse.statusCode == 401 {
                    // Token expired — refresh and retry once
                    print("[Sync] Token expired, refreshing...")
                    try await AuthManager.shared.refreshAccessToken()
                    request = AuthManager.shared.authenticatedRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    request.timeoutInterval = 30

                    let (_, retryResponse) = try await URLSession.shared.data(for: request)
                    guard let retryHttp = retryResponse as? HTTPURLResponse else {
                        try DatabaseManager.shared.markAsSyncFailed(ids: ids)
                        return
                    }
                    
                    if retryHttp.statusCode == 201 {
                        try DatabaseManager.shared.markAsSynced(ids: ids)
                        print("[Sync] Synced \(ids.count) activities after token refresh")
                    } else {
                        print("[Sync] Retry failed with status: \(retryHttp.statusCode)")
                        try DatabaseManager.shared.markAsSyncFailed(ids: ids)
                    }
                } else if httpResponse.statusCode == 201 {
                    // 5. Success — mark as synced
                    try DatabaseManager.shared.markAsSynced(ids: ids)
                    print("[Sync] Successfully synced \(ids.count) activities")
                } else {
                    // Unexpected response — revert isSyncing so they retry
                    if let body = String(data: responseData, encoding: .utf8) {
                        print("[Sync] Unexpected response (\(httpResponse.statusCode)): \(body)")
                    }
                    try DatabaseManager.shared.markAsSyncFailed(ids: ids)
                }

            } catch {
                // Handle offline gracefully — just skip, retry next cycle
                print("[Sync] Failed (will retry): \(error.localizedDescription)")
            }
        }
    }
}
