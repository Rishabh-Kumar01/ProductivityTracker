//
//  AlertManager.swift
//  ProductivityTracker
//
import Foundation
import UserNotifications
import Combine

struct AlertRule: Codable, Identifiable {
    var id: String
    var matchType: String
    var pattern: String
    var limitMinutes: Int
    var autoBlock: Bool
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, pattern
        case matchType = "match_type"
        case limitMinutes = "limit_minutes"
        case autoBlock = "auto_block"
        case displayName = "display_name"
    }
}

struct AlertRulesResponse: Codable {
    let status: String
    let data: [AlertRule]
}

class AlertManager: ObservableObject {
    static let shared = AlertManager()
    
    @Published var alertRules: [AlertRule] = []
    
    private var timer: Timer?
    private var notifiedWarnPatterns: Set<String> = []
    private var notifiedBlockPatterns: Set<String> = []
    
    private init() {
        requestNotificationPermission()
        // Run the day-change check immediately on launch so any stale auto-blocks from a
        // previous day are cleared before the first 60s timer fires. This is what unblocks
        // Brave (and any other auto-blocked app) on the morning after a limit was hit.
        runDayChangeCheckIfNeeded()
        startPolling()
    }

    /// Clears notification flags and calls BlockManager.clearAllAutoBlocks() if the current
    /// calendar day differs from the last stored day. Safe to call repeatedly — no-op on same day.
    private func runDayChangeCheckIfNeeded() {
        let currentDayStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let lastDayStr = UserDefaults.standard.string(forKey: "alertLastCheckedDay")
        guard currentDayStr != lastDayStr else { return }

        notifiedWarnPatterns.removeAll()
        notifiedBlockPatterns.removeAll()
        BlockManager.shared.clearAllAutoBlocks()
        UserDefaults.standard.set(currentDayStr, forKey: "alertLastCheckedDay")
        print("[AlertManager] Day change detected at launch, cleared auto-blocks")
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else if let err = error {
                print("Notification permission error: " + err.localizedDescription)
                print("⚠️ Please go to System Settings > Notifications > ProductivityTracker and toggle 'Allow notifications' ON.")
            }
        }
    }
    
    private func startPolling() {
        // Rule fetching is nudged via SSE push. The 5-minute timer is a safety net
        // for the case where SSE is disconnected (lid closed, network down).
        // Local alert checks against the cached rules still need to run frequently,
        // so checkAlerts() still ticks every 60s.
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkAlerts()
        }

        Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.fetchRules()
        }
    }
    
    func fetchRules() {
        guard let url = URL(string: "\(APIConfig.baseURL)/alerts") else { return }
        let request = AuthManager.shared.authenticatedRequest(url: url)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Not logged in yet, skip silently
                return
            }
            if let data = data {
                do {
                    let decoded = try JSONDecoder().decode(AlertRulesResponse.self, from: data)
                    DispatchQueue.main.async {
                        self?.alertRules = decoded.data
                    }
                } catch {
                    print("Error decoding alert rules: " + String(reflecting: error))
                    if let stringData = String(data: data, encoding: .utf8) {
                        print("Raw data received: " + stringData)
                    }
                }
            } else if let err = error {
                print("Error fetching rules: " + err.localizedDescription)
            }
        }.resume()
    }
    
    private func checkAlerts() {
        // Day-change reset runs BEFORE the alertRules check so that yesterday's auto-blocks get
        // cleared even if today's rule fetch hasn't succeeded yet (cold backend, network out, etc).
        runDayChangeCheckIfNeeded()

        guard !alertRules.isEmpty else { return }

        for rule in alertRules {
            let limitSeconds = rule.limitMinutes * 60
            var usageSeconds = 0
            
            do {
                if rule.matchType == "app" {
                    // Primary: match by bundleId
                    usageSeconds = try DatabaseManager.shared.getDailyUsage(forBundleId: rule.pattern)
                    // Fallback: match by app name (for legacy rules stored with display names)
                    if usageSeconds == 0 {
                        usageSeconds = try DatabaseManager.shared.getDailyUsage(forAppName: rule.pattern)
                    }
                } else if rule.matchType == "category" {
                    usageSeconds = try DatabaseManager.shared.getDailyUsage(forCategory: rule.pattern)
                } else if rule.matchType == "domain" {
                    usageSeconds = try DatabaseManager.shared.getDailyUsage(forDomain: rule.pattern)
                }

                let displayLabel = rule.displayName ?? rule.pattern

                // 100% Limit Trigger
                if usageSeconds >= limitSeconds {
                    if !notifiedBlockPatterns.contains(rule.pattern) {
                        sendNotification(title: "Time Limit Reached!", body: "You have used up your " + String(rule.limitMinutes) + "m limit for " + displayLabel)
                        notifiedBlockPatterns.insert(rule.pattern)
                        
                        if rule.autoBlock {
                            DispatchQueue.main.async {
                                if rule.matchType == "app" {
                                    BlockManager.shared.autoBlockApp(bundleId: rule.pattern)
                                } else if rule.matchType == "domain" {
                                    BlockManager.shared.autoBlockDomain(domain: rule.pattern)
                                }
                            }
                        }
                    }
                }
                // 80% Warning Trigger
                else if usageSeconds >= Int(Double(limitSeconds) * 0.8) {
                    if !notifiedWarnPatterns.contains(rule.pattern) {
                        let remaining = Int(Double(rule.limitMinutes) * 0.2)
                        sendNotification(title: "Approaching Time Limit", body: "You have less than " + String(remaining) + "m remaining for " + displayLabel)
                        notifiedWarnPatterns.insert(rule.pattern)
                    }
                }
                
            } catch {
                print("Error checking usage for rule " + rule.pattern + ": " + error.localizedDescription)
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                print("Error showing notification: " + err.localizedDescription)
            }
        }
    }
}
