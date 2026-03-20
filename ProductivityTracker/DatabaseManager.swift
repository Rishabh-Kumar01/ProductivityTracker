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
    var category: String = "Uncategorized"
    var productivityScore: Int = 2  // 0-4 scale: 0=veryDistracting, 4=veryProductive
    var startTime: Date
    var endTime: Date
    var duration: Int  // seconds
    var isIdle: Bool = false
    var isSynced: Bool = false

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

    // MARK: - Sync Helpers

    func getUnsyncedActivities(limit: Int = 500) throws -> [ActivityRecord] {
        try dbQueue.read { db in
            try ActivityRecord
                .filter(Column("isSynced") == false)
                .order(Column("startTime").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func markAsSynced(ids: [String]) throws {
        _ = try dbQueue.write { db in
            try ActivityRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("isSynced").set(to: true))
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
}
