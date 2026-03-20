//
//  OnboardingView.swift
//  ProductivityTracker
//
//  Created by Rishabh on 19/03/26.
//

import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentStep = 0
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<4) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 24)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: automationStep
                case 3: doneStep
                default: EmptyView()
                }
            }
            .transition(.opacity)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 && currentStep < 3 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if currentStep == 0 {
                    Button("Get Started") {
                        withAnimation { currentStep = 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else if currentStep == 1 {
                    if accessibilityGranted {
                        Button("Continue") {
                            withAnimation { currentStep = 2 }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if currentStep == 2 {
                    Button("Continue") {
                        withAnimation { currentStep = 3 }
                    }
                    .buttonStyle(.borderedProminent)
                } else if currentStep == 3 {
                    Button("Start Tracking") {
                        completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 24)
            .padding(.horizontal, 32)
        }
        .frame(width: 480, height: 400)
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Step Views

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Welcome to ProductivityTracker")
                .font(.title2.bold())

            Text("Track your app and website usage, get productivity scores, and stay focused with blocking features.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundColor(accessibilityGranted ? .green : .orange)

            Text("Accessibility Permission")
                .font(.title2.bold())

            Text("ProductivityTracker needs Accessibility access to read window titles and track which apps you use.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)

            if accessibilityGranted {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.headline)
            } else {
                Button("Open System Settings") {
                    openAccessibilitySettings()
                    startPollingAccessibility()
                }
                .buttonStyle(.bordered)

                Text("Grant access, then this will auto-advance.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
            if !accessibilityGranted {
                // Trigger the system prompt
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as NSDictionary
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                startPollingAccessibility()
            }
        }
    }

    private var automationStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "applescript.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Automation Permission")
                .font(.title2.bold())

            Text("When tracking starts, macOS will ask for permission to access browsers like Safari and Chrome. This is needed for URL tracking — please allow it.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)

            Label("macOS will prompt automatically", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            Text("ProductivityTracker will now run in your menu bar. Click the chart icon anytime to see your stats.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)
        }
    }

    // MARK: - Helpers

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if AXIsProcessTrusted() {
                accessibilityGranted = true
                pollTimer?.invalidate()
                pollTimer = nil
                // Auto-advance after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation { currentStep = 2 }
                }
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isComplete = true
    }
}
