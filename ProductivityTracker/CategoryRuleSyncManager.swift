import Foundation

class CategoryRuleSyncManager {
    static let shared = CategoryRuleSyncManager()

    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 10 * 60 // 10 minutes

    /// Backoff for a sync that failed, so a bad first attempt does not leave the
    /// engine ruleless for a full interval.
    ///
    /// A failed sync used to cost ten minutes of tracking, and the cost is not
    /// visible: every visit in that window is written "Uncategorized", which
    /// reads exactly like a domain nobody has a rule for. Nothing backfills, so
    /// a single failure at launch permanently mis-labels the next ten minutes
    /// of history.
    private let retryDelays: [TimeInterval] = [5, 20, 60, 180]
    private var retryIndex = 0
    private var retryTimer: Timer?

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
                // Pin to macos — server scopes rules by platform.
                guard let url = URL(string: "\(APIConfig.baseURL)/categories/merged?platform=macos") else { return }

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
                        await self.syncSucceeded()
                    } else {
                        await self.scheduleRetry()
                    }
                    return
                }

                if httpResponse.statusCode == 200 {
                    try processResponse(data)
                    await self.syncSucceeded()
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                    NSLog("[CategoryRuleSync] failed with status \(httpResponse.statusCode): \(responseStr)")
                    await self.scheduleRetry()
                }
            } catch {
                NSLog("[CategoryRuleSync] error: \(error.localizedDescription)")
                await self.scheduleRetry()
            }
        }
    }

    @MainActor
    private func syncSucceeded() {
        retryIndex = 0
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// Retries soon rather than at the next scheduled sync.
    @MainActor
    private func scheduleRetry() {
        guard retryIndex < retryDelays.count else {
            NSLog("[CategoryRuleSync] giving up until the next scheduled sync — "
                  + "activity recorded until then will be Uncategorized")
            return
        }
        let delay = retryDelays[retryIndex]
        retryIndex += 1
        NSLog("[CategoryRuleSync] retrying in \(Int(delay))s")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.performSync()
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

        // An empty set would wipe the local rules and leave everything
        // Uncategorized until the next successful sync. A response that parsed
        // to nothing is far more likely to be a bad response than a user who
        // genuinely has no rules at all.
        guard !rules.isEmpty else {
            NSLog("[CategoryRuleSync] server returned no rules — keeping the existing set")
            return
        }

        try DatabaseManager.shared.replaceCategoryRules(rules)
        CategoryEngine.shared.refreshRules()
        NSLog("[CategoryRuleSync] synced \(rules.count) rules")
    }
}
