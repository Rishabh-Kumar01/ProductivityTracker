import Foundation

class CategoryRuleSyncManager {
    static let shared = CategoryRuleSyncManager()

    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 10 * 60 // 10 minutes

    func start() {
        // Sync immediately on start
        performSync()

        // Schedule periodic sync
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: syncInterval,
            repeats: true
        ) { [weak self] _ in
            self?.performSync()
        }
        syncTimer?.tolerance = 30
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func performSync() {
        guard AuthManager.shared.isLoggedIn else { return }

        Task {
            do {
                guard let url = URL(string: "\(APIConfig.baseURL)/categories/merged") else { return }

                var request = AuthManager.shared.authenticatedRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 30

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 401 {
                    // Token expired — refresh and retry once
                    try await AuthManager.shared.refreshAccessToken()
                    var retryRequest = AuthManager.shared.authenticatedRequest(url: url)
                    retryRequest.httpMethod = "GET"
                    retryRequest.timeoutInterval = 30

                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    if let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 {
                        try processResponse(retryData)
                    }
                    return
                }

                if httpResponse.statusCode == 200 {
                    try processResponse(data)
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                    print("[CategoryRuleSync] Sync failed with status \(httpResponse.statusCode): \(responseStr)")
                }
            } catch {
                print("[CategoryRuleSync] Sync error: \(error.localizedDescription)")
            }
        }
    }

    private func processResponse(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rulesArray = json["data"] as? [[String: Any]] else {
            print("[CategoryRuleSync] Invalid response format")
            return
        }

        let rules: [CategoryRule] = rulesArray.compactMap { dict in
            guard let matchType = dict["match_type"] as? String,
                  let pattern = dict["pattern"] as? String,
                  let category = dict["category"] as? String,
                  let score = dict["productivity_score"] as? Int else {
                return nil
            }
            return CategoryRule(
                matchType: matchType,
                matchValue: pattern,
                category: category,
                productivityScore: score
            )
        }

        try DatabaseManager.shared.replaceCategoryRules(rules)
        CategoryEngine.shared.refreshRules()
        print("[CategoryRuleSync] Synced \(rules.count) rules from server")
    }
}
