import Foundation
import Combine

/// Sleep enforcement on the Mac.
///
/// The spec puts the overlay on both clients deliberately: a phone-only version
/// is sidestepped by opening the laptop, and the laptop is where most of the
/// hours are.
///
/// Unlike Android this does not watch the foreground app. There is no dialler
/// or alarm to exempt here, and covering the whole screen during declared hours
/// IS the behaviour — so the only questions are whether enforcement is on,
/// whether it is his night, and whether he is inside an escape.
///
/// The server's clock comes with the policy. A Mac whose clock is wrong would
/// otherwise hand itself an hour, and the clock is the one thing in this
/// arrangement that must not be negotiable.
@MainActor
final class SleepManager: ObservableObject {

    static let shared = SleepManager()

    @Published private(set) var state: SleepState?
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private var pollTimer: Timer?
    private var skew: TimeInterval = 0
    private var reprieveUntil: Date = .distantPast
    private let apiBaseURL = APIConfig.baseURL

    private init() {}

    func start() {
        NSLog("[Sleep] manager started")
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        SleepOverlayController.shared.hide()
    }

    private func serverNow() -> Date { Date().addingTimeInterval(skew) }

    private var inReprieve: Bool { serverNow() < reprieveUntil }

    /// Whether the screen should be covered right now.
    var shouldCover: Bool {
        guard let s = state else { return false }
        return s.enforced && s.asleep && !inReprieve
    }

    func refresh() {
        guard AuthManager.shared.isLoggedIn else { return }
        guard let url = URL(string: "\(apiBaseURL)/chastity/sleep/state") else { return }

        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                // Same gap the cage clock had. Without this the policy freezes
                // at whatever it last read, and a stale policy either covers
                // the screen at noon or leaves it clear at 3am.
                Task { @MainActor in
                    try? await AuthManager.shared.refreshAccessToken()
                    self?.refresh()
                }
                return
            }
            guard let data = data, error == nil else {
                NSLog("[Sleep] policy refresh failed: \(error?.localizedDescription ?? "no data")")
                return
            }
            guard let wrapper = try? JSONDecoder().decode(SleepStateResponse.self, from: data) else {
                NSLog("[Sleep] could not decode /chastity/sleep/state")
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.state = wrapper.data
                if let serverNow = wrapper.data.serverNowDate {
                    self.skew = serverNow.timeIntervalSince(Date())
                }
                if let until = wrapper.data.emergency.activeUntilDate {
                    self.reprieveUntil = until
                }
                self.applyPolicy()
            }
        }.resume()
    }

    /// Raise or drop the overlay to match the policy.
    ///
    /// Called on every refresh rather than only on change: the reasons it ends
    /// — the hours passing, an escape expiring — are not events anything here
    /// observes, so a poll is what closes it.
    private func applyPolicy() {
        let cover = shouldCover
        if cover && !SleepOverlayController.shared.isVisible {
            NSLog("[Sleep] covering the screen")
            SleepOverlayController.shared.show()
            report(kind: "shown")
        } else if !cover && SleepOverlayController.shared.isVisible {
            NSLog("[Sleep] uncovering — \(state?.asleep == true ? "escape active" : "out of hours")")
            SleepOverlayController.shared.hide()
        }
    }

    var escapesLeft: Int {
        guard let e = state?.emergency else { return 0 }
        return max(0, e.allowed - e.used)
    }

    var escapeMinutes: Int { state?.emergency.minutes ?? 5 }

    /// The wall-clock moment the screen frees itself.
    var wakesAt: Date? { state?.wakesAtDate }

    /// Unconditional, exactly like the panic release. No approval, no delay.
    func takeEscape() {
        guard let url = URL(string: "\(apiBaseURL)/chastity/sleep/emergency") else { return }
        isBusy = true

        Task { @MainActor in
            defer { isBusy = false }
            do {
                var status = try await post(url: url)
                if status == 401 {
                    try await AuthManager.shared.refreshAccessToken()
                    status = try await post(url: url)
                }
                NSLog("[Sleep] escape responded \(status)")
                if (200...299).contains(status) {
                    lastError = nil
                    // Open the door immediately rather than waiting for the
                    // next poll — a minute of a covered screen after pressing
                    // the escape would read as the button not working.
                    reprieveUntil = serverNow().addingTimeInterval(TimeInterval(escapeMinutes * 60))
                    SleepOverlayController.shared.hide()
                    refresh()
                } else if status == 409 {
                    lastError = "No escapes left tonight."
                } else {
                    lastError = "That did not work (\(status))."
                }
            } catch {
                lastError = error.localizedDescription
                NSLog("[Sleep] escape failed: \(error.localizedDescription)")
            }
        }
    }

    private func post(url: URL) async throws -> Int {
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Recorded, never prevented.
    ///
    /// A window on macOS cannot be made unkillable — force-quitting the app
    /// always works. Rather than fight that badly and lose, this follows what
    /// tamper detection already does with `/etc/hosts`: report it and let her
    /// see it.
    func report(kind: String) {
        guard let url = URL(string: "\(apiBaseURL)/chastity/sleep/event") else { return }
        var request = AuthManager.shared.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["platform": "macos", "kind": kind]
        )
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(code) {
                NSLog("[Sleep] overlay event '\(kind)' not recorded (\(code))")
            }
        }.resume()
    }
}

// MARK: - Wire types

nonisolated struct SleepEmergencyInfo: Decodable {
    let activeUntil: String?
    let used: Int
    let allowed: Int
    let minutes: Int

    var activeUntilDate: Date? { activeUntil.flatMap(SleepState.parse) }
}

nonisolated struct SleepState: Decodable {
    let enforced: Bool
    let asleep: Bool
    let sleepStart: String?
    let sleepEnd: String?
    let wakesAt: String?
    let emergency: SleepEmergencyInfo
    let serverNow: String

    var wakesAtDate: Date? { wakesAt.flatMap(SleepState.parse) }
    var serverNowDate: Date? { SleepState.parse(serverNow) }

    /// The API sends fractional seconds on some fields and not others, so both
    /// are tried rather than assuming.
    static func parse(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

nonisolated struct SleepStateResponse: Decodable {
    let status: String
    let data: SleepState
}
