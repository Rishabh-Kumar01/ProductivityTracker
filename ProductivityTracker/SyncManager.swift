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
    private var isSyncing = false

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
        guard !isSyncing else { return }
        guard AuthManager.shared.isLoggedIn else {
            print("[Sync] Skipping — not logged in")
            return
        }

        isSyncing = true

        Task {
            defer { isSyncing = false }

            do {
                // 1. Fetch unsynced records from SQLite (max 100 to avoid timeout)
                let records = try DatabaseManager.shared.getUnsyncedActivities(limit: 100)
                guard !records.isEmpty else {
                    print("[Sync] No unsynced activities")
                    return
                }
                
                print("[Sync] Found \(records.count) unsynced activities, uploading...")

                // 2. Convert to JSON payload
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

                // 3. POST to server with explicit timeout
                let url = URL(string: "\(baseURL)/activities/bulk")!
                var request = AuthManager.shared.authenticatedRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                request.timeoutInterval = 30

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }
                
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
                    guard let retryHttp = retryResponse as? HTTPURLResponse else { return }
                    
                    if retryHttp.statusCode == 201 {
                        let ids = records.map { $0.id }
                        try DatabaseManager.shared.markAsSynced(ids: ids)
                        print("[Sync] Synced \(ids.count) activities after token refresh")
                    } else {
                        print("[Sync] Retry failed with status: \(retryHttp.statusCode)")
                    }
                } else if httpResponse.statusCode == 201 {
                    // 4. Mark as synced in SQLite
                    let ids = records.map { $0.id }
                    try DatabaseManager.shared.markAsSynced(ids: ids)
                    print("[Sync] Successfully synced \(ids.count) activities")
                } else {
                    // Log unexpected response
                    if let body = String(data: responseData, encoding: .utf8) {
                        print("[Sync] Unexpected response (\(httpResponse.statusCode)): \(body)")
                    }
                }

            } catch {
                // Handle offline gracefully — just skip, retry next cycle
                print("[Sync] Failed (will retry): \(error.localizedDescription)")
            }
        }
    }
}
