//
//  HostsHelperProtocol.swift
//  ProductivityTracker
//
//  Shared XPC protocol between the main app and the privileged helper.
//  This file must be added to BOTH targets in Xcode.
//

import Foundation

@objc protocol HostsHelperProtocol {
    /// Write blocked domains to /etc/hosts. Replaces existing block section.
    func updateBlockedDomains(_ domains: [String], reply: @escaping (Bool, String?) -> Void)
    
    /// Read currently blocked domains from /etc/hosts block section.
    func getBlockedDomains(reply: @escaping ([String]) -> Void)
    
    /// Get SHA-256 hash of the block section for tamper detection.
    func getHostsFileHash(reply: @escaping (String) -> Void)
    
    /// Remove all blocks from /etc/hosts.
    func removeAllBlocks(reply: @escaping (Bool) -> Void)
    
    /// Flush DNS resolver cache.
    func flushDNS(reply: @escaping (Bool) -> Void)
}
