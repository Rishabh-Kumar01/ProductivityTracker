//
//  main.swift
//  ProductivityTrackerHelper
//
//  LaunchDaemon entry point. Listens for XPC connections
//  from the main app and handles /etc/hosts modifications.
//

import Foundation

// MARK: - XPC Service Delegate

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        newConnection.exportedObject = HelperHandler()
        newConnection.resume()
        return true
    }
}

// MARK: - Protocol Implementation

class HelperHandler: NSObject, HostsHelperProtocol {
    
    func updateBlockedDomains(_ domains: [String],
                              reply: @escaping (Bool, String?) -> Void) {
        do {
            try HostsFileManager.updateBlockedDomains(domains)
            let _ = HostsFileManager.flushDNSCache()
            NSLog("[Helper] Updated \(domains.count) domains in /etc/hosts")
            reply(true, nil)
        } catch {
            NSLog("[Helper] Failed to update domains: \(error)")
            reply(false, error.localizedDescription)
        }
    }
    
    func getBlockedDomains(reply: @escaping ([String]) -> Void) {
        let domains = HostsFileManager.getBlockedDomains()
        reply(domains)
    }
    
    func getHostsFileHash(reply: @escaping (String) -> Void) {
        let hash = HostsFileManager.getBlockSectionHash()
        reply(hash)
    }
    
    func removeAllBlocks(reply: @escaping (Bool) -> Void) {
        do {
            try HostsFileManager.removeAllBlocks()
            let _ = HostsFileManager.flushDNSCache()
            NSLog("[Helper] Removed all blocks from /etc/hosts")
            reply(true)
        } catch {
            NSLog("[Helper] Failed to remove blocks: \(error)")
            reply(false)
        }
    }
    
    func flushDNS(reply: @escaping (Bool) -> Void) {
        let success = HostsFileManager.flushDNSCache()
        reply(success)
    }
}

// MARK: - Main

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.rishabh.productivitytracker.helper")
listener.delegate = delegate
listener.resume()

NSLog("[Helper] ProductivityTrackerHelper daemon started, listening for XPC connections...")

RunLoop.current.run()
