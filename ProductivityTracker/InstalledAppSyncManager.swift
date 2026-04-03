import Foundation

class InstalledAppSyncManager {
    static let shared = InstalledAppSyncManager()

    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private let lastSyncKey = "InstalledAppSyncManager.lastSyncDate"

    func start() {
        // Sync immediately if never synced or interval has passed
        if shouldSync() {
            performSync()
        }

        // Schedule periodic check
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: 60 * 60, // check every hour if sync is due
            repeats: true
        ) { [weak self] _ in
            if self?.shouldSync() == true {
                self?.performSync()
            }
        }
        syncTimer?.tolerance = 60
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func shouldSync() -> Bool {
        guard let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastSync) >= syncInterval
    }

    private func performSync() {
        guard AuthManager.shared.isLoggedIn else { return }

        Task {
            do {
                let apps = InstalledAppScanner.shared.scan()
                print("[InstalledAppSync] Scanned \(apps.count) apps")

                let payload: [[String: String]] = apps.map { app in
                    ["bundleId": app.bundleId, "appName": app.appName]
                }

                guard let url = URL(string: "\(APIConfig.baseURL)/apps/sync") else { return }

                var request = AuthManager.shared.authenticatedRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 30

                let body: [String: Any] = ["apps": payload]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 401 {
                    // Token expired — refresh and retry once
                    try await AuthManager.shared.refreshAccessToken()
                    var retryRequest = AuthManager.shared.authenticatedRequest(url: url)
                    retryRequest.httpMethod = "POST"
                    retryRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    retryRequest.httpBody = request.httpBody
                    retryRequest.timeoutInterval = 30

                    let (_, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    if let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 {
                        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
                        print("[InstalledAppSync] Synced successfully (after token refresh)")
                    }
                    return
                }

                if httpResponse.statusCode == 200 {
                    UserDefaults.standard.set(Date(), forKey: lastSyncKey)
                    print("[InstalledAppSync] Synced successfully")
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                    print("[InstalledAppSync] Sync failed with status \(httpResponse.statusCode): \(responseStr)")
                }
            } catch {
                print("[InstalledAppSync] Sync error: \(error.localizedDescription)")
            }
        }
    }
}
