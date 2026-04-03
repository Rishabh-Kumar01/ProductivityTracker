//
//  DatabaseManager.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import Foundation
import GRDB

// MARK: - Activity Record Model

struct ActivityRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String = UUID().uuidString
    var appName: String
    var bundleId: String?
    var windowTitle: String?
    var url: String?
    var domain: String?
    var category: String = "Uncategorized"
    var productivityScore: Int = 2  // 0-4 scale: 0=veryDistracting, 4=veryProductive
    var startTime: Date
    var endTime: Date
    var duration: Int  // seconds
    var isIdle: Bool = false
    var isSynced: Bool = false
    var isSyncing: Bool = false

    static let databaseTableName = "activities"
}

// MARK: - Category Rule Model

struct CategoryRule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String = UUID().uuidString
    var matchType: String   // "app", "bundleId", "domain"
    var matchValue: String  // e.g., "Xcode", "com.apple.Safari", "github.com"
    var category: String    // e.g., "Development", "Social Media"
    var productivityScore: Int // 0-4
    var isUserOverride: Bool = false

    static let databaseTableName = "category_rules"
}

// MARK: - Blocker Models

struct BlockedDomain: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var domain: String
    var source: String
    var tempUnblockUntil: Date?
    var addedAt: Date?
    
    static let databaseTableName = "blocked_domains"
}

struct BlocklistSource: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var url: String?
    var domainCount: Int = 0
    var lastUpdated: Date?
    var isEnabled: Bool = true
    
    static let databaseTableName = "blocklist_sources"
}

// MARK: - Database Manager

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    private init() {
        // Create app support directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ProductivityTracker")

        try! FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        let dbPath = appSupport.appendingPathComponent("tracker.sqlite").path

        // Configure with WAL mode for performance
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        dbQueue = try! DatabaseQueue(path: dbPath, configuration: config)

        // Run migrations
        try! migrator.migrate(dbQueue)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-activities") { db in
            try db.create(table: "activities") { t in
                t.column("id", .text).primaryKey()
                t.column("appName", .text).notNull()
                t.column("bundleId", .text)
                t.column("windowTitle", .text)
                t.column("url", .text)
                t.column("category", .text).defaults(to: "Uncategorized")
                t.column("productivityScore", .integer).defaults(to: 2)
                t.column("startTime", .datetime).notNull().indexed()
                t.column("endTime", .datetime).notNull()
                t.column("duration", .integer).notNull()
                t.column("isIdle", .boolean).defaults(to: false)
                t.column("isSynced", .boolean).defaults(to: false)
            }
        }

        migrator.registerMigration("v2-category_rules") { db in
            try db.create(table: "category_rules") { t in
                t.column("id", .text).primaryKey()
                t.column("matchType", .text).notNull()
                t.column("matchValue", .text).notNull()
                t.column("category", .text).notNull()
                t.column("productivityScore", .integer).notNull()
                t.column("isUserOverride", .boolean).defaults(to: false)

                t.uniqueKey(["matchType", "matchValue"])
            }
        }

        migrator.registerMigration("v3-sync-fix") { db in
            try db.alter(table: "activities") { t in
                t.add(column: "isSyncing", .boolean).defaults(to: false)
            }
        }

        migrator.registerMigration("v4-domain") { db in
            try db.alter(table: "activities") { t in
                t.add(column: "domain", .text)
            }
        }

        migrator.registerMigration("v5-blocklist") { db in
            try db.create(table: "blocked_domains") { t in
                t.column("id", .text).primaryKey()
                t.column("domain", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("tempUnblockUntil", .datetime)
                t.column("addedAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_blocked_domain", on: "blocked_domains", columns: ["domain"], unique: true)

            try db.create(table: "blocklist_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("url", .text)
                t.column("domainCount", .integer).defaults(to: 0)
                t.column("lastUpdated", .datetime)
                t.column("isEnabled", .boolean).defaults(to: true)
            }
        }

        return migrator
    }

    // MARK: - Insert

    func insertActivity(_ record: ActivityRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    func insertCategoryRule(_ rule: CategoryRule) throws {
        try dbQueue.write { db in
            try rule.insert(db)
        }
    }

    // MARK: - Query Category Rules

    func getAllCategoryRules() throws -> [CategoryRule] {
        try dbQueue.read { db in
            try CategoryRule.fetchAll(db)
        }
    }

    func getRulesCount() throws -> Int {
        try dbQueue.read { db in
            try CategoryRule.fetchCount(db)
        }
    }

    // MARK: - Query Daily Usage
    
    struct TopApp: Identifiable {
        var id = UUID()
        var appName: String
        var duration: Int
    }
    
    struct DailySummary {
        var productivityScore: Double
        var topApps: [TopApp]
    }
    
    func getTodaysSummary() throws -> DailySummary {
        try dbQueue.read { db in
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            
            // Calculate Top 3 Apps
            let rows = try Row.fetchAll(db, sql: """
                SELECT appName, SUM(duration) as totalDuration
                FROM activities
                WHERE startTime >= ? AND startTime < ? AND isIdle = 0
                GROUP BY appName
                ORDER BY totalDuration DESC
                LIMIT 3
                """, arguments: [startOfDay, endOfDay])
                
            let topApps = rows.map { row in
                TopApp(appName: row["appName"] as String, duration: row["totalDuration"] as Int)
            }
            
            // Calculate average Productivity Score weighted by duration
            let scoreRow = try Row.fetchOne(db, sql: """
                SELECT SUM(productivityScore * duration) as weightedScore, SUM(duration) as totalDuration
                FROM activities
                WHERE startTime >= ? AND startTime < ? AND isIdle = 0
                """, arguments: [startOfDay, endOfDay])
            
            var avgScore = 2.0
            if let row = scoreRow, let weightedScore: Double = row["weightedScore"], let totalDuration: Double = row["totalDuration"], totalDuration > 0 {
                // Productivity score is 0-4. Return raw average, no scaling.
                avgScore = weightedScore / totalDuration
            }
            
            return DailySummary(productivityScore: avgScore, topApps: topApps)
        }
    }
    
    func getTodayTopDomains(limit: Int = 3) throws -> [(domain: String, duration: Int)] {
        try dbQueue.read { db in
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            
            let rows = try Row.fetchAll(db, sql: """
                SELECT domain, SUM(duration) as totalDuration
                FROM activities
                WHERE domain IS NOT NULL AND domain != '' AND startTime >= ? AND startTime < ? AND isIdle = 0
                GROUP BY domain
                ORDER BY totalDuration DESC
                LIMIT ?
                """, arguments: [startOfDay, endOfDay, limit])
                
            return rows.map { row in
                (domain: row["domain"] as String, duration: row["totalDuration"] as Int)
            }
        }
    }
    
    func getDailyUsage(forBundleId bundleId: String, on date: Date = Date()) throws -> Int {
        try dbQueue.read { db in
            let startOfDay = Calendar.current.startOfDay(for: date)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            
            let totalSeconds = try Int.fetchOne(db, sql: """
                SELECT SUM(duration) FROM activities 
                WHERE bundleId = ? AND startTime >= ? AND startTime < ? AND isIdle = 0
                """, arguments: [bundleId, startOfDay, endOfDay])
            
            return totalSeconds ?? 0
        }
    }
    
    func getDailyUsage(forCategory category: String, on date: Date = Date()) throws -> Int {
        try dbQueue.read { db in
            let startOfDay = Calendar.current.startOfDay(for: date)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            
            let totalSeconds = try Int.fetchOne(db, sql: """
                SELECT SUM(duration) FROM activities 
                WHERE category = ? AND startTime >= ? AND startTime < ? AND isIdle = 0
                """, arguments: [category, startOfDay, endOfDay])
            
            return totalSeconds ?? 0
        }
    }

    // MARK: - Sync Helpers

    func getUnsyncedActivities(limit: Int = 500) throws -> [ActivityRecord] {
        try dbQueue.read { db in
            try ActivityRecord
                .filter(Column("isSynced") == false && Column("isSyncing") == false)
                .order(Column("startTime").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func markAsSyncing(ids: [String]) throws {
        _ = try dbQueue.write { db in
            try ActivityRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("isSyncing").set(to: true))
        }
    }

    func markAsSynced(ids: [String]) throws {
        _ = try dbQueue.write { db in
            try ActivityRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db,
                    Column("isSynced").set(to: true),
                    Column("isSyncing").set(to: false)
                )
        }
    }

    func markAsSyncFailed(ids: [String]) throws {
        _ = try dbQueue.write { db in
            try ActivityRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("isSyncing").set(to: false))
        }
    }

    /// Reset records stuck with isSyncing=true (from crashes or network failures)
    func resetStuckSyncingRecords() throws {
        let count = try dbQueue.write { db in
            try ActivityRecord
                .filter(Column("isSynced") == false && Column("isSyncing") == true)
                .updateAll(db, Column("isSyncing").set(to: false))
        }
        if count > 0 {
            print("[DatabaseManager] Reset \(count) stuck syncing records")
        }
    }

    // MARK: - Today Queries

    func getTodayActivities() throws -> [ActivityRecord] {
        try dbQueue.read { db in
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

            return try ActivityRecord
                .filter(Column("startTime") >= startOfDay && Column("startTime") < endOfDay)
                .filter(Column("isIdle") == false)
                .order(Column("startTime").desc)
                .fetchAll(db)
        }
    }

    func getTodayTotalDuration() throws -> Int {
        try dbQueue.read { db in
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

            return try ActivityRecord
                .filter(Column("startTime") >= startOfDay && Column("startTime") < endOfDay)
                .filter(Column("isIdle") == false)
                .select(sum(Column("duration")))
                .fetchOne(db) ?? 0
        }
    }

    func getTodayProductivityScore() throws -> Double {
        try dbQueue.read { db in
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

            let activities = try ActivityRecord
                .filter(Column("startTime") >= startOfDay && Column("startTime") < endOfDay)
                .filter(Column("isIdle") == false)
                .fetchAll(db)

            let totalDuration = activities.reduce(0) { $0 + $1.duration }
            guard totalDuration > 0 else { return 0.0 }

            let weightedSum = activities.reduce(0.0) { sum, act in
                sum + Double(act.duration) * Double(act.productivityScore)
            }
            // Scale: 0 = all very distracting, 50 = all neutral, 100 = all very productive
            return (weightedSum / (Double(totalDuration) * 4.0)) * 100.0
        }
    }

    // MARK: - Blocklist Data Access
    
    func replaceBlockedDomains(_ domains: [BlockedDomain]) throws {
        _ = try dbQueue.write { db in
            try BlockedDomain.deleteAll(db)
            for domain in domains {
                var d = domain
                try d.insert(db)
            }
        }
    }
    
    func insertBlockedDomain(domain: String, source: String) throws {
        _ = try dbQueue.write { db in
            var record = BlockedDomain(
                id: UUID().uuidString,
                domain: domain,
                source: source,
                tempUnblockUntil: nil,
                addedAt: Date()
            )
            try record.insert(db, onConflict: .ignore)
        }
    }
    
    func getActiveBlockedDomains() throws -> [String] {
        try dbQueue.read { db in
            let now = Date()
            let records = try BlockedDomain
                .filter(Column("tempUnblockUntil") == nil || Column("tempUnblockUntil") < now)
                .fetchAll(db)
            return records.map { $0.domain }
        }
    }
    
    func clearExpiredTempUnblocks() throws -> Bool {
        var didClear = false
        _ = try dbQueue.write { db in
            let now = Date()
            let expiredCount = try BlockedDomain
                .filter(Column("tempUnblockUntil") != nil && Column("tempUnblockUntil") < now)
                .updateAll(db, Column("tempUnblockUntil").set(to: NSNull()))
            didClear = expiredCount > 0
        }
        return didClear
    }
}
