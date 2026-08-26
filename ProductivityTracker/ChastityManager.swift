import Foundation
import Combine

/// The cage clock on the Mac.
///
/// The elapsed time is computed locally from `startedAt`, exactly as the phone
/// and the dashboard do — a ticking number is arithmetic, not data, so nothing
/// polls to render it. Status is refetched only to pick up state changes.
///
/// `skew` corrects for a Mac whose clock is wrong. This is the number the whole
/// arrangement is built around; showing a wrong one would be worse than showing
/// none.
@MainActor
final class ChastityManager: ObservableObject {

    static let shared = ChastityManager()

    @Published private(set) var status: ChastityStatus?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private var statusTimer: Timer?
    private var tickTimer: Timer?
    private var skew: TimeInterval = 0
    private let apiBaseURL = APIConfig.baseURL

    private init() {}

    func start() {
        refresh()
        // State changes only. Five minutes is plenty — the clock itself is
        // local, so this is not what makes the display move.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        statusTimer?.invalidate(); statusTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func tick() {
        guard let started = status?.startedAtDate else { elapsed = 0; return }
        elapsed = Date().addingTimeInterval(skew).timeIntervalSince(started)
    }

    func refresh() {
        guard AuthManager.shared.isLoggedIn else { return }
        guard let url = URL(string: "\(apiBaseURL)/chastity/status") else { return }

        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                // Same gap as the release had: without this the clock quietly
                // freezes at whatever it last read.
                Task { @MainActor in
                    try? await AuthManager.shared.refreshAccessToken()
                    self?.refresh()
                }
                return
            }
            guard let data = data, error == nil else { return }
            guard let wrapper = try? JSONDecoder().decode(ChastityStatusResponse.self, from: data) else {
                NSLog("[Chastity] could not decode /chastity/status")
                return
            }
            Task { @MainActor in
                self?.status = wrapper.data
                if let serverNow = wrapper.data.serverNowDate {
                    self?.skew = serverNow.timeIntervalSince(Date())
                }
                self?.tick()
            }
        }.resume()
    }

    /// Unconditional, and reachable from the menu bar without navigating.
    ///
    /// Refreshes and retries once on 401, as every other manager here does.
    /// Without that an expired access token made the button do nothing at all —
    /// and the error it set was invisible, because the menu bar popover closes
    /// the moment the dialog is dismissed. For the one control that must always
    /// work, silent failure is the worst outcome available.
    func panicRelease(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(apiBaseURL)/chastity/panic") else { return completion(false) }
        isBusy = true

        Task { @MainActor in
            defer { isBusy = false }
            do {
                var status = try await self.postPanic(url: url)
                if status == 401 {
                    NSLog("[Chastity] panic got 401 — refreshing token and retrying")
                    try await AuthManager.shared.refreshAccessToken()
                    status = try await self.postPanic(url: url)
                }
                NSLog("[Chastity] panic release responded \(status)")

                if (200...299).contains(status) {
                    self.lastError = nil
                    self.refresh()
                    completion(true)
                } else {
                    self.lastError = "Release failed (\(status)). You are still recorded as locked."
                    completion(false)
                }
            } catch {
                NSLog("[Chastity] panic release failed: \(error.localizedDescription)")
                self.lastError = "Release failed: \(error.localizedDescription)"
                completion(false)
            }
        }
    }

    private func postPanic(url: URL) async throws -> Int {
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// "3d 04:12:07" — days only appear once there are some.
    var elapsedText: String {
        let total = max(0, Int(elapsed))
        let d = total / 86400, h = (total % 86400) / 3600
        let m = (total % 3600) / 60, s = total % 60
        let clock = String(format: "%02d:%02d:%02d", h, m, s)
        return d > 0 ? "\(d)d \(clock)" : clock
    }

    /// Compact enough for the menu bar itself, where space is scarce.
    var menuBarText: String {
        let total = max(0, Int(elapsed))
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Wire types
//
// Explicitly nonisolated. The project defaults new types to MainActor, but
// these are decoded inside a URLSession callback on a background thread — a
// main-actor-isolated Decodable conformance is a warning today and an error
// under Swift 6.

nonisolated struct ChastityRelease: Decodable {
    let state: String            // none | waiting | available | open
    let opensAt: String?
    let closesBy: String?
    let penaltyMinutes: Int?
}

nonisolated struct ChastityStatus: Decodable {
    let active: Bool
    let status: String?          // pending | active
    let startedAt: String?
    let streakStartedAt: String?
    let releaseIntervalMinutes: Int?
    let release: ChastityRelease?
    let serverNow: String

    /// The API sends ISO-8601 with fractional seconds; the default formatter
    /// rejects those, which would silently leave the clock at zero.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    var startedAtDate: Date? { Self.parse(startedAt) }
    var serverNowDate: Date? { Self.parse(serverNow) }
}

nonisolated struct ChastityStatusResponse: Decodable {
    let status: String
    let data: ChastityStatus
}

extension ISO8601DateFormatter {
    /// The API sends fractional seconds; the default formatter rejects them.
    static let chastity: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
