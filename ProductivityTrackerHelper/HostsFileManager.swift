//
//  HostsFileManager.swift
//  ProductivityTrackerHelper
//
//  Handles reading, writing, and hashing the /etc/hosts file.
//  Runs with root privileges as part of the LaunchDaemon.
//

import Foundation
import CryptoKit

struct HostsFileManager {
    
    static let hostsPath = "/etc/hosts"
    static let markerStart = "# ===== PRODUCTIVITYTRACKER-BLOCK-START ====="
    static let markerEnd   = "# ===== PRODUCTIVITYTRACKER-BLOCK-END ====="
    
    // MARK: - Update blocked domains
    
    static func updateBlockedDomains(_ domains: [String]) throws {
        let currentContent = try String(contentsOfFile: hostsPath, encoding: .utf8)
        
        // Remove existing block section
        let cleaned = removeBlockSection(from: currentContent)
        
        // Build new block section
        var blockSection = "\n\(markerStart)\n"
        let dateStr = ISO8601DateFormatter().string(from: Date())
        blockSection += "# Generated: \(dateStr)\n"
        blockSection += "# Domains: \(domains.count)\n"
        
        for domain in domains {
            let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\"", with: "")
            guard !clean.isEmpty else { continue }
            
            blockSection += "0.0.0.0 \(clean)\n"
            if !clean.hasPrefix("www.") {
                blockSection += "0.0.0.0 www.\(clean)\n"
            }
            blockSection += "::1 \(clean)\n"
            if !clean.hasPrefix("www.") {
                blockSection += "::1 www.\(clean)\n"
            }
        }
        blockSection += "\(markerEnd)\n"
        
        // Write back
        let newContent = cleaned + blockSection
        try newContent.write(toFile: hostsPath, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Read blocked domains from hosts
    
    static func getBlockedDomains() -> [String] {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            return []
        }
        
        guard let blockSection = extractBlockSection(from: content) else {
            return []
        }
        
        var domains = Set<String>()
        for line in blockSection.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            
            // Parse lines like "0.0.0.0 example.com" or "::1 example.com"
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                let domain = String(parts[1]).trimmingCharacters(in: .whitespaces)
                // Skip www. variants to avoid duplicates
                if !domain.hasPrefix("www.") {
                    domains.insert(domain)
                }
            }
        }
        
        return Array(domains).sorted()
    }
    
    // MARK: - Remove all blocks
    
    static func removeAllBlocks() throws {
        let currentContent = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let cleaned = removeBlockSection(from: currentContent)
        try cleaned.write(toFile: hostsPath, atomically: true, encoding: .utf8)
    }
    
    // MARK: - SHA-256 hash of block section
    
    static func getBlockSectionHash() -> String {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8),
              let section = extractBlockSection(from: content) else {
            return "none"
        }
        
        let data = Data(section.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Flush DNS
    
    static func flushDNSCache() -> Bool {
        let flush1 = Process()
        flush1.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush1.arguments = ["-flushcache"]
        
        let flush2 = Process()
        flush2.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        flush2.arguments = ["-HUP", "mDNSResponder"]
        
        do {
            try flush1.run()
            flush1.waitUntilExit()
            try flush2.run()
            flush2.waitUntilExit()
            return true
        } catch {
            NSLog("[Helper] DNS flush error: \(error)")
            return false
        }
    }
    
    // MARK: - Private helpers
    
    private static func removeBlockSection(from content: String) -> String {
        guard let startRange = content.range(of: markerStart),
              let endRange = content.range(of: markerEnd) else {
            return content
        }
        
        // Find the full range including the newline before the start marker
        var removeStart = startRange.lowerBound
        if removeStart > content.startIndex {
            let before = content.index(before: removeStart)
            if content[before] == "\n" {
                removeStart = before
            }
        }
        
        // Include the newline after the end marker
        var removeEnd = endRange.upperBound
        if removeEnd < content.endIndex && content[removeEnd] == "\n" {
            removeEnd = content.index(after: removeEnd)
        }
        
        var result = content
        result.removeSubrange(removeStart..<removeEnd)
        return result
    }
    
    private static func extractBlockSection(from content: String) -> String? {
        guard let startRange = content.range(of: markerStart),
              let endRange = content.range(of: markerEnd) else {
            return nil
        }
        return String(content[startRange.lowerBound..<endRange.upperBound])
    }
}
