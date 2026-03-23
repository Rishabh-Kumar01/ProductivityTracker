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
            ("bundleId", "com.todesktop.230313mzl4w4u92", "Development", .veryProductive), // Cursor
            ("bundleId", "dev.zed.Zed", "Development", .veryProductive),
            ("bundleId", "com.sublimetext.4", "Development", .veryProductive),
            ("bundleId", "com.panic.Nova", "Development", .veryProductive),
            ("bundleId", "com.vscodium", "Development", .veryProductive),
            ("bundleId", "com.github.atom", "Development", .veryProductive),
            ("bundleId", "abnerworks.Typora", "Development", .veryProductive),
            
            // AI Tools
            ("domain", "claude.ai", "AI Tools", .veryProductive),
            ("domain", "chatgpt.com", "AI Tools", .veryProductive),
            ("domain", "chat.openai.com", "AI Tools", .veryProductive),
            ("domain", "bard.google.com", "AI Tools", .veryProductive),
            ("domain", "perplexity.ai", "AI Tools", .veryProductive),
            ("bundleId", "com.openai.chat", "AI Tools", .veryProductive), // ChatGPT Mac app
            
            // Project Management
            ("domain", "linear.app", "Project Management", .productive),
            ("domain", "asana.com", "Project Management", .productive),
            ("domain", "trello.com", "Project Management", .productive),
            ("domain", "jira.atlassian.com", "Project Management", .productive),
            ("domain", "monday.com", "Project Management", .productive),
            ("domain", "clickup.com", "Project Management", .productive),
            
            // Communication & Collaboration
            ("app", "Slack", "Communication", .neutral),
            ("app", "Discord", "Communication", .distracting),
            ("bundleId", "com.hnc.Discord", "Communication", .distracting),
            ("app", "Microsoft Teams", "Communication", .neutral),
            ("bundleId", "com.microsoft.teams2", "Communication", .neutral),
            ("app", "Zoom", "Meetings", .productive),
            ("bundleId", "us.zoom.xos", "Meetings", .productive),
            ("app", "Mail", "Email", .neutral),
            ("domain", "mail.google.com", "Email", .neutral),
            ("domain", "calendar.google.com", "Planning", .productive),
            ("bundleId", "ru.keepcoder.Telegram", "Communication", .neutral),
            ("bundleId", "org.whispersystems.signal-desktop", "Communication", .neutral),
            
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
            ("app", "Spotify", "Music", .neutral),
            ("app", "Music", "Music", .neutral),
            
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
