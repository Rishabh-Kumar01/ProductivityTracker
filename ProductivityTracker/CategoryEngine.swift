//
//  CategoryEngine.swift
//  ProductivityTracker
//
//  Created by Rishabh on 20/03/26.
//

import Foundation

// MARK: - Productivity Level

enum ProductivityLevel: Int, Codable {
    case veryDistracting = 0
    case distracting = 1
    case neutral = 2
    case productive = 3
    case veryProductive = 4
    
    var value: Int { rawValue }
}

// MARK: - Category Engine

class CategoryEngine {
    static let shared = CategoryEngine()
    
    private var rules: [CategoryRule] = []
    
    private init() {
        // Load rules or insert defaults on first run
        do {
            let count = try DatabaseManager.shared.getRulesCount()
            if count == 0 {
                try insertDefaultRules()
            }
            refreshRules()
        } catch {
            print("Failed to initialize CategoryEngine: \\(error)")
        }
    }
    
    func refreshRules() {
        do {
            rules = try DatabaseManager.shared.getAllCategoryRules()
        } catch {
            print("Failed to load rules: \\(error)")
        }
    }
    
    // MARK: - Resolution Logic
    
    /// Resolve category and score for a given app / domain
    func resolve(appName: String, bundleId: String?, domain: String?) -> (category: String, score: Int) {
        // 1. User overrides (highest priority) -> we filter by isUserOverride == true
        if let rule = findMatch(appName: appName, bundleId: bundleId, domain: domain, userOverridesOnly: true) {
            return (rule.category, rule.productivityScore)
        }
        
        // 2. Default matches (domain > bundleId > appName)
        if let rule = findMatch(appName: appName, bundleId: bundleId, domain: domain, userOverridesOnly: false) {
            return (rule.category, rule.productivityScore)
        }
        
        // 3. Fallback
        return ("Uncategorized", ProductivityLevel.neutral.value)
    }
    
    private func findMatch(appName: String, bundleId: String?, domain: String?, userOverridesOnly: Bool) -> CategoryRule? {
        let matchingRules = userOverridesOnly ? rules.filter { $0.isUserOverride } : rules.filter { !$0.isUserOverride }
        
        // Match by domain first
        if let domain = domain,
           let match = matchingRules.first(where: { $0.matchType == "domain" && $0.matchValue.caseInsensitiveCompare(domain) == .orderedSame }) {
            return match
        }
        
        // Match by bundleId second
        if let bundleId = bundleId,
           let match = matchingRules.first(where: { $0.matchType == "bundleId" && $0.matchValue == bundleId }) {
            return match
        }
        
        // Match by appName third
        if let match = matchingRules.first(where: { $0.matchType == "app" && $0.matchValue.caseInsensitiveCompare(appName) == .orderedSame }) {
            return match
        }
        
        return nil
    }
    
    // MARK: - Default Rules
    
    private func insertDefaultRules() throws {
        let defaults: [(type: String, val: String, cat: String, score: ProductivityLevel)] = [
            // Development
            ("app", "Xcode", "Development", .veryProductive),
            ("bundleId", "com.microsoft.VSCode", "Development", .veryProductive),
            ("app", "Terminal", "Development", .veryProductive),
            ("app", "iTerm2", "Development", .veryProductive),
            ("domain", "github.com", "Development", .productive),
            ("domain", "stackoverflow.com", "Development", .productive),
            
            // Communication & Collaboration
            ("app", "Slack", "Communication", .neutral),
            ("app", "Discord", "Communication", .distracting),
            ("app", "Microsoft Teams", "Communication", .neutral),
            ("app", "Zoom", "Meetings", .productive),
            ("app", "Mail", "Email", .neutral),
            ("domain", "mail.google.com", "Email", .neutral),
            ("domain", "calendar.google.com", "Planning", .productive),
            
            // Design
            ("app", "Figma", "Design", .veryProductive),
            ("app", "Sketch", "Design", .veryProductive),
            
            // Browsers (neutral by themselves, waiting for domain)
            ("app", "Safari", "Browsing", .neutral),
            ("app", "Google Chrome", "Browsing", .neutral),
            ("app", "Arc", "Browsing", .neutral),
            ("app", "Brave Browser", "Browsing", .neutral),
            ("app", "Microsoft Edge", "Browsing", .neutral),
            
            // Social Media (distracting)
            ("domain", "twitter.com", "Social Media", .veryDistracting),
            ("domain", "x.com", "Social Media", .veryDistracting),
            ("domain", "facebook.com", "Social Media", .veryDistracting),
            ("domain", "instagram.com", "Social Media", .veryDistracting),
            ("domain", "reddit.com", "Social Media", .distracting),
            ("domain", "tiktok.com", "Social Media", .veryDistracting),
            ("domain", "linkedin.com", "Social Media", .neutral),
            
            // Entertainment
            ("domain", "youtube.com", "Video", .distracting),
            ("domain", "netflix.com", "Video", .veryDistracting),
            ("domain", "twitch.tv", "Video", .veryDistracting),
            ("app", "Spotify", "Music", .neutral),
            ("app", "Music", "Music", .neutral),
            
            // Info / News
            ("domain", "news.ycombinator.com", "News", .distracting),
            ("domain", "nytimes.com", "News", .distracting)
        ]
        
        for rule in defaults {
            let r = CategoryRule(
                matchType: rule.type,
                matchValue: rule.val,
                category: rule.cat,
                productivityScore: rule.score.value
            )
            try DatabaseManager.shared.insertCategoryRule(r)
        }
    }
}
