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
        // Load rules or insert defaults on first run.
        // If logged in, skip local defaults — CategoryRuleSyncManager will populate from server.
        do {
            let count = try DatabaseManager.shared.getRulesCount()
            if count == 0 && !AuthManager.shared.isLoggedIn {
                try insertDefaultRules()
            }
            refreshRules()
        } catch {
            print("Failed to initialize CategoryEngine: \(error)")
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
    func resolve(appName: String, bundleId: String?, windowTitle: String?, domain: String?) -> (category: String, score: Int) {
        // 1. User overrides (highest priority) -> we filter by isUserOverride == true
        if let rule = findMatch(appName: appName, bundleId: bundleId, domain: domain, userOverridesOnly: true) {
            return (rule.category, rule.productivityScore)
        }
        
        let isBrowser = BrowserURLTracker().isBrowser(bundleId: bundleId)
        
        // 2. Default Domain matches (if we have a domain, this overrides the browser's base category)
        if let domain = domain {
            if let rule = findDomainMatch(domain: domain, userOverridesOnly: false) {
                return (rule.category, rule.productivityScore)
            }
            // If it's a browser and has a domain but NO domain rule matched,
            // we STILL skip the bundleId/appName so it falls through to Uncategorized
            // instead of just "Browsing" (unless they are matched by the heuristic below)
        } else if !isBrowser {
            // 3. Bundle ID or App Name (only if NOT a browser with a domain)
            if let rule = findAppMatch(appName: appName, bundleId: bundleId, userOverridesOnly: false) {
                return (rule.category, rule.productivityScore)
            }
        } else if isBrowser && domain == nil {
             // 3b. Browser with NO domain captured (e.g., just opened, on start page)
             if let rule = findAppMatch(appName: appName, bundleId: bundleId, userOverridesOnly: false) {
                return (rule.category, rule.productivityScore)
            }
        }
        
        // 4. Window title heuristics (Prompt 2.2)
        if let heuristicMatch = heuristicCategory(appName: appName, windowTitle: windowTitle) {
            return heuristicMatch
        }
        
        // 5. Fallback
        return ("Uncategorized", ProductivityLevel.neutral.value)
    }
    
    private func heuristicCategory(appName: String, windowTitle: String?) -> (category: String, score: Int)? {
        guard let title = windowTitle?.lowercased() else { return nil }
        
        // Development patterns — file extensions commonly seen in code editors
        let devExtensions = [".swift", ".js", ".ts", ".tsx", ".jsx", ".py", ".rs", ".go",
                             ".java", ".cpp", ".c", ".h", ".css", ".html", ".json", 
                             ".yaml", ".yml", ".env", ".md", ".sql", ".sh", ".rb",
                             ".kt", ".vue", ".svelte", ".toml", ".xml", ".gradle"]
        let devKeywords = ["debug", "breakpoint", "console", "terminal", "commit",
                           "merge", "branch", "pull request", "diff", "build succeeded",
                           "build failed", "running on", "localhost:", "package.json",
                           "node_modules", "git", "— main", "— master"]
        if devExtensions.contains(where: { title.contains($0) }) 
            || devKeywords.contains(where: { title.contains($0) }) {
            return ("Development", ProductivityLevel.veryProductive.value)
        }
        
        // Writing patterns
        let docExtensions = [".docx", ".doc", ".pages", ".tex", ".rtf", ".odt"]
        let docKeywords = ["page ", "word count", "google docs", "notion"]
        if docExtensions.contains(where: { title.contains($0) })
            || docKeywords.contains(where: { title.contains($0) }) {
            return ("Writing", ProductivityLevel.veryProductive.value)
        }
        
        // Design patterns
        let designKeywords = ["figma", "sketch", "canvas", "artboard", "layer",
                              "adobe", "photoshop", "illustrator"]
        if designKeywords.contains(where: { title.contains($0) }) {
            return ("Design", ProductivityLevel.productive.value)
        }
        
        return nil // Fall through to "Uncategorized"
    }
    
    private func findMatch(appName: String, bundleId: String?, domain: String?, userOverridesOnly: Bool) -> CategoryRule? {
        if let domain = domain, let match = findDomainMatch(domain: domain, userOverridesOnly: userOverridesOnly) {
            return match
        }
        return findAppMatch(appName: appName, bundleId: bundleId, userOverridesOnly: userOverridesOnly)
    }
    
    private func findDomainMatch(domain: String, userOverridesOnly: Bool) -> CategoryRule? {
        let matchingRules = userOverridesOnly ? rules.filter { $0.isUserOverride } : rules.filter { !$0.isUserOverride }
        
        // Match exact or suffix (e.g., rules has "github.com", domain is "gist.github.com")
        for rule in matchingRules where rule.matchType == "domain" {
            let val = rule.matchValue.lowercased()
            let lowerDomain = domain.lowercased()
            if lowerDomain == val || lowerDomain.hasSuffix("." + val) {
                return rule
            }
        }
        return nil
    }

    private func findAppMatch(appName: String, bundleId: String?, userOverridesOnly: Bool) -> CategoryRule? {
        let matchingRules = userOverridesOnly ? rules.filter { $0.isUserOverride } : rules.filter { !$0.isUserOverride }
        let appRules = matchingRules.filter { $0.matchType == "app" }

        // 1. Primary: match by bundleId (exact match against pattern)
        if let bundleId = bundleId,
           let match = appRules.first(where: { $0.matchValue == bundleId }) {
            return match
        }

        // 2. Fallback: match by app name (case-insensitive)
        if let match = appRules.first(where: { $0.matchValue.caseInsensitiveCompare(appName) == .orderedSame }) {
            if bundleId != nil {
                print("[CategoryEngine] Fallback name match for '\(appName)' — consider adding bundleId rule")
            }
            return match
        }

        // 3. Legacy: check for old "bundleId" match type (pre-migration data)
        if let bundleId = bundleId,
           let match = matchingRules.first(where: { $0.matchType == "bundleId" && $0.matchValue == bundleId }) {
            return match
        }

        return nil
    }
    
    // MARK: - Default Rules
    
    private func insertDefaultRules() throws {
        // All app entries use unified "app" match type.
        // Pattern is bundleId where known, app name otherwise.
        let defaults: [(type: String, val: String, cat: String, score: ProductivityLevel)] = [
            // Development
            ("app", "com.apple.dt.Xcode", "Development", .veryProductive),
            ("app", "com.microsoft.VSCode", "Development", .veryProductive),
            ("app", "com.apple.Terminal", "Development", .veryProductive),
            ("app", "com.googlecode.iterm2", "Development", .veryProductive),
            ("domain", "github.com", "Development", .productive),
            ("domain", "stackoverflow.com", "Development", .productive),
            ("app", "com.todesktop.230313mzl4w4u92", "Development", .veryProductive), // Cursor
            ("app", "dev.zed.Zed", "Development", .veryProductive),
            ("app", "com.sublimetext.4", "Development", .veryProductive),
            ("app", "com.panic.Nova", "Development", .veryProductive),
            ("app", "com.vscodium", "Development", .veryProductive),
            ("app", "com.github.atom", "Development", .veryProductive),
            ("app", "abnerworks.Typora", "Development", .veryProductive),

            // AI Tools
            ("domain", "claude.ai", "AI Tools", .veryProductive),
            ("domain", "chatgpt.com", "AI Tools", .veryProductive),
            ("domain", "chat.openai.com", "AI Tools", .veryProductive),
            ("domain", "bard.google.com", "AI Tools", .veryProductive),
            ("domain", "perplexity.ai", "AI Tools", .veryProductive),
            ("app", "com.openai.chat", "AI Tools", .veryProductive), // ChatGPT Mac app

            // Project Management
            ("domain", "linear.app", "Project Management", .productive),
            ("domain", "asana.com", "Project Management", .productive),
            ("domain", "trello.com", "Project Management", .productive),
            ("domain", "jira.atlassian.com", "Project Management", .productive),
            ("domain", "monday.com", "Project Management", .productive),
            ("domain", "clickup.com", "Project Management", .productive),

            // Communication & Collaboration
            ("app", "com.tinyspeck.slackmacgap", "Communication", .neutral), // Slack
            ("app", "com.hnc.Discord", "Communication", .distracting),
            ("app", "com.microsoft.teams2", "Communication", .neutral),
            ("app", "us.zoom.xos", "Meetings", .productive),
            ("app", "com.apple.mail", "Email", .neutral),
            ("domain", "mail.google.com", "Email", .neutral),
            ("domain", "calendar.google.com", "Planning", .productive),
            ("app", "ru.keepcoder.Telegram", "Communication", .neutral),
            ("app", "org.whispersystems.signal-desktop", "Communication", .neutral),

            // Design
            ("app", "com.figma.Desktop", "Design", .veryProductive),
            ("app", "com.bohemiancoding.sketch3", "Design", .veryProductive),

            // Browsers (neutral by themselves, waiting for domain)
            ("app", "com.apple.Safari", "Browsing", .neutral),
            ("app", "com.google.Chrome", "Browsing", .neutral),
            ("app", "company.thebrowser.Browser", "Browsing", .neutral), // Arc
            ("app", "com.brave.Browser", "Browsing", .neutral),
            ("app", "com.microsoft.edgemac", "Browsing", .neutral),

            // Social Media (distracting)
            ("domain", "twitter.com", "Social Media", .veryDistracting),
            ("domain", "x.com", "Social Media", .veryDistracting),
            ("domain", "facebook.com", "Social Media", .veryDistracting),
            ("domain", "instagram.com", "Social Media", .veryDistracting),
            ("domain", "reddit.com", "Social Media", .distracting),
            ("domain", "tiktok.com", "Social Media", .veryDistracting),
            ("domain", "linkedin.com", "Social Media", .distracting),
            ("domain", "threads.net", "Social Media", .veryDistracting),
            ("domain", "snapchat.com", "Social Media", .veryDistracting),
            ("domain", "pinterest.com", "Social Media", .distracting),
            ("domain", "old.reddit.com", "Social Media", .distracting),

            // Entertainment
            ("domain", "youtube.com", "Video", .distracting),
            ("domain", "netflix.com", "Video", .veryDistracting),
            ("domain", "twitch.tv", "Video", .veryDistracting),
            ("domain", "primevideo.com", "Video", .veryDistracting),
            ("domain", "hotstar.com", "Video", .veryDistracting),
            ("domain", "jiocinema.com", "Video", .veryDistracting),
            ("domain", "hulu.com", "Video", .veryDistracting),
            ("domain", "crunchyroll.com", "Video", .veryDistracting),
            ("app", "com.spotify.client", "Music", .neutral),
            ("app", "com.apple.Music", "Music", .neutral),

            // Info / News
            ("domain", "news.ycombinator.com", "News", .distracting),
            ("domain", "nytimes.com", "News", .distracting),
            ("domain", "moneycontrol.com", "News", .distracting)
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
