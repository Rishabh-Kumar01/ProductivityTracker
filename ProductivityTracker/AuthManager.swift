//
//  AuthManager.swift
//  ProductivityTracker
//
//  Created by Rishabh on 23/03/26.
//

import Foundation
import KeychainAccess
import Combine

// MARK: - Auth Manager

class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isLoggedIn = false
    @Published var userEmail: String?

    private let keychain = Keychain(service: "com.rishabh.ProductivityTracker")
    private let baseURL = "http://localhost:3000/api"

    private var accessToken: String? {
        get { try? keychain.get("accessToken") }
        set {
            if let value = newValue {
                try? keychain.set(value, key: "accessToken")
            } else {
                try? keychain.remove("accessToken")
            }
        }
    }

    private var refreshToken: String? {
        get { try? keychain.get("refreshToken") }
        set {
            if let value = newValue {
                try? keychain.set(value, key: "refreshToken")
            } else {
                try? keychain.remove("refreshToken")
            }
        }
    }

    private init() {
        isLoggedIn = accessToken != nil
        userEmail = try? keychain.get("userEmail")
    }

    // MARK: - OTP Flow

    func requestOTP(email: String) async throws {
        let url = URL(string: "\(baseURL)/auth/otp/request")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AuthError.networkError }

        if httpResponse.statusCode != 200 {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = body?["message"] as? String ?? "Failed to request OTP"
            throw AuthError.serverError(message)
        }
    }

    func verifyOTP(email: String, otp: String) async throws {
        let url = URL(string: "\(baseURL)/auth/otp/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email,
            "otp": otp,
            "deviceName": Host.current().localizedName ?? "Mac",
            "os": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AuthError.networkError }

        if httpResponse.statusCode != 200 {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = body?["message"] as? String ?? "Failed to verify OTP"
            throw AuthError.serverError(message)
        }

        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resultData = result?["data"] as? [String: Any]

        accessToken = resultData?["accessToken"] as? String
        refreshToken = resultData?["refreshToken"] as? String

        if let user = resultData?["user"] as? [String: Any] {
            userEmail = user["email"] as? String
            try? keychain.set(userEmail ?? "", key: "userEmail")
        }

        DispatchQueue.main.async {
            self.isLoggedIn = true
            NotificationCenter.default.post(name: NSNotification.Name("UserDidLogin"), object: nil)
        }
    }

    // MARK: - Token Management

    func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw AuthError.notLoggedIn }

        let url = URL(string: "\(baseURL)/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": rt])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AuthError.networkError }

        if httpResponse.statusCode == 401 {
            // Refresh token expired — force re-login
            logout()
            throw AuthError.sessionExpired
        }

        guard httpResponse.statusCode == 200 else { throw AuthError.networkError }

        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resultData = result?["data"] as? [String: Any]
        accessToken = resultData?["accessToken"] as? String
    }

    func logout() {
        // Revoke on server (fire and forget)
        if let rt = refreshToken {
            Task {
                let url = URL(string: "\(baseURL)/auth/logout")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": rt])
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        accessToken = nil
        refreshToken = nil
        userEmail = nil
        try? keychain.remove("userEmail")

        DispatchQueue.main.async {
            self.isLoggedIn = false
            NotificationCenter.default.post(name: NSNotification.Name("UserDidLogout"), object: nil)
        }
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case networkError
    case serverError(String)
    case notLoggedIn
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .networkError: return "Network error. Please check your connection."
        case .serverError(let msg): return msg
        case .notLoggedIn: return "Not logged in."
        case .sessionExpired: return "Session expired. Please log in again."
        }
    }
}
