//
//  main.swift
//  ProductivityTrackerHelper
//
//  LaunchDaemon entry point. Listens for XPC connections from the main app
//  and handles /etc/hosts modifications with root privileges.
//

import Foundation

// MARK: - XPC Service Delegate

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        
        newConnection.invalidationHandler = {
            NSLog("[Helper] Connection invalidated")
        }
        newConnection.interruptionHandler = {
            NSLog("[Helper] Connection interrupted")
        }
        
        newConnection.resume()
        NSLog("[Helper] Accepted new XPC connection")
        return true
    }
}

// MARK: - Protocol Implementation

class HelperService: NSObject, HostsHelperProtocol {
    
    func updateBlockedDomains(_ domains: [String], reply: @escaping (Bool, String?) -> Void) {
        NSLog("[Helper] Updating \(domains.count) blocked domains")
        do {
            try HostsFileManager.updateBlockedDomains(domains)
            _ = HostsFileManager.flushDNSCache()
            let hash = HostsFileManager.getBlockSectionHash()
            NSLog("[Helper] Hosts updated, hash: \(hash)")
            reply(true, nil)
        } catch {
            NSLog("[Helper] Error updating hosts: \(error)")
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
        NSLog("[Helper] Removing all blocks")
        do {
            try HostsFileManager.removeAllBlocks()
            _ = HostsFileManager.flushDNSCache()
            reply(true)
        } catch {
            NSLog("[Helper] Error removing blocks: \(error)")
            reply(false)
        }
    }
    
    func flushDNS(reply: @escaping (Bool) -> Void) {
        let result = HostsFileManager.flushDNSCache()
        reply(result)
    }
}

// MARK: - Entry Point

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.rishabh.productivitytracker.helper")
listener.delegate = delegate
listener.resume()

NSLog("[Helper] ProductivityTrackerHelper started, listening for XPC connections")
RunLoop.current.run()
