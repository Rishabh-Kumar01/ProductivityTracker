//
//  SettingsView.swift
//  ProductivityTracker
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            CategoriesSettingsView()
                .tabItem {
                    Label("Categories", systemImage: "folder")
                }
            
            BlockingSettingsView()
                .tabItem {
                    Label("Blocking", systemImage: "nosign")
                }
            
            AlertsSettingsView()
                .tabItem {
                    Label("Alerts", systemImage: "bell")
                }
            
            AccountSettingsView()
                .tabItem {
                    Label("Account", systemImage: "person.circle")
                }
            
            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    
    var body: some View {
        Form {
            Section(header: Text("Startup").font(.headline)) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        do {
                            if isEnabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to change login item: \\(error)")
                        }
                    }
                Text("Automatically start tracking when you log in.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom)
            
            Section(header: Text("Tracking").font(.headline)) {
                Text("Idle timeout: 5 minutes")
                Text("Sync interval: 5 minutes")
                Text("These values are managed by the server in pro mode.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CategoriesSettingsView: View {
    var body: some View {
        VStack {
            Text("Category Rules")
                .font(.headline)
            Text("Manage overrides for apps and websites via your Web Dashboard.")
                .foregroundColor(.secondary)
            
            Button("Open Web Dashboard") {
                if let url = URL(string: "http://localhost:5173/settings") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct BlockingSettingsView: View {
    @ObservedObject var blockManager = BlockManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked Applications")
                .font(.headline)
            List(Array(blockManager.blockedBundleIds), id: \.self) { bundleId in
                Text(bundleId)
            }
            
            Text("Blocked Websites")
                .font(.headline)
            List(Array(blockManager.blockedWebsites), id: \.self) { url in
                Text(url)
            }
        }
    }
}

struct AlertsSettingsView: View {
    @ObservedObject var alertManager = AlertManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Time Limits")
                .font(.headline)
            
            if alertManager.alertRules.isEmpty {
                Text("No active alerts.")
                    .foregroundColor(.secondary)
            } else {
                List(alertManager.alertRules) { rule in
                    HStack {
                        Text(rule.pattern)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\\(rule.limitMinutes)m")
                        if rule.autoBlock {
                            Image(systemName: "lock.fill").foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }
}

struct AccountSettingsView: View {
    @ObservedObject var authManager = AuthManager.shared
    
    @State private var email: String = ""
    @State private var otp: String = ""
    @State private var isOtpSent: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 60, height: 60)
                .foregroundColor(.blue)
            
            if authManager.isLoggedIn {
                Text("Logged in as:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(authManager.userEmail ?? "Unknown User")
                    .font(.headline)
                
                Button("Log Out") {
                    authManager.logout()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Text("Not logged in")
                    .font(.headline)
                
                VStack(spacing: 12) {
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    TextField("Email Address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 250)
                        .disabled(isOtpSent || isLoading)
                    
                    if isOtpSent {
                        TextField("6-Digit OTP", text: $otp)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 250)
                            .disabled(isLoading)
                        
                        Button(isLoading ? "Verifying..." : "Verify OTP") {
                            verifyOTP()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || otp.isEmpty)
                        
                        Button("Cancel") {
                            isOtpSent = false
                            otp = ""
                            errorMessage = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.top, 4)
                    } else {
                        Button(isLoading ? "Sending..." : "Send Magic Code") {
                            requestOTP()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || email.isEmpty)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func requestOTP() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await authManager.requestOTP(email: email)
                isOtpSent = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
    
    private func verifyOTP() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await authManager.verifyOTP(email: email, otp: otp)
                // If successful, authManager.isLoggedIn updates the UI
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .foregroundColor(.blue)
            
            Text("ProductivityTracker")
                .font(.title)
                .bold()
            
            Text("Version 1.0.0")
                .foregroundColor(.secondary)
            
            Text("© 2026 Rishabh")
                .font(.caption)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
