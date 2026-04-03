import Foundation

struct InstalledApp {
    let bundleId: String
    let appName: String
}

class InstalledAppScanner {
    static let shared = InstalledAppScanner()

    /// Directories to scan for .app bundles.
    /// Includes Utilities subdirectories so Terminal, Activity Monitor, etc. are found.
    private let scanDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSString("~/Applications").expandingTildeInPath
    ]

    func scan() -> [InstalledApp] {
        var results: [String: InstalledApp] = [:] // keyed by bundleId to deduplicate
        let fileManager = FileManager.default

        for directory in scanDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }

            for item in contents where item.hasSuffix(".app") {
                let appPath = (directory as NSString).appendingPathComponent(item)
                let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")

                guard let plistData = fileManager.contents(atPath: plistPath),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                      let bundleId = plist["CFBundleIdentifier"] as? String else {
                    continue
                }

                // Use display name, then bundle name, then filename
                let appName = (plist["CFBundleDisplayName"] as? String)
                    ?? (plist["CFBundleName"] as? String)
                    ?? item.replacingOccurrences(of: ".app", with: "")

                // Skip Apple system daemons / background agents
                if bundleId.hasPrefix("com.apple.") && isSystemAgent(plist) {
                    continue
                }

                results[bundleId] = InstalledApp(bundleId: bundleId, appName: appName)
            }
        }

        return Array(results.values).sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Filter out background-only system agents that have no UI
    private func isSystemAgent(_ plist: [String: Any]) -> Bool {
        // LSBackgroundOnly or LSUIElement apps from Apple are usually daemons
        if let bgOnly = plist["LSBackgroundOnly"] as? Bool, bgOnly { return true }
        return false
    }
}
