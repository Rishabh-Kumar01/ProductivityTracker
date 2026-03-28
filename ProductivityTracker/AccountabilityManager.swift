//
//  AccountabilityManager.swift
//  ProductivityTracker
//

import Foundation
import Combine

class AccountabilityManager: ObservableObject {
    static let shared = AccountabilityManager()
    
    @Published var isAccountabilityActive: Bool = false
    @Published var partnerEmail: String?
    
    private let apiBaseURL = APIConfig.baseURL
    
    private init() {}
    
    func checkStatus() {
        guard AuthManager.shared.isLoggedIn else {
            self.isAccountabilityActive = false
            TamperMonitor.shared.stop()
            HeartbeatManager.shared.stop()
            return
        }
        
        guard let url = URL(string: "\(apiBaseURL)/accountability/status") else { return }
        let request = AuthManager.shared.authenticatedRequest(url: url)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[AccountabilityManager] Status check failed: \(error)")
                return
            }
            
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataObj = json["data"] as? [String: Any] {
                    
                    let isActive = dataObj["isActive"] as? Bool ?? false
                    let email = dataObj["partnerEmail"] as? String
                    
                    DispatchQueue.main.async {
                        self?.isAccountabilityActive = isActive
                        self?.partnerEmail = email
                        
                        if isActive {
                            TamperMonitor.shared.start()
                        } else {
                            TamperMonitor.shared.stop()
                        }
                    }
                }
            } catch {
                print("[AccountabilityManager] JSON Error: \(error)")
            }
        }.resume()
    }
}
