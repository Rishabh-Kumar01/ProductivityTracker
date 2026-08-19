import Foundation
import AppKit

/// Registers this Mac with the server so it appears in the owner's device list
/// and can later be given its own wallpaper rendering and brightness settings.
///
/// Runs on every launch. Registration is an upsert server-side, so repeating it
/// is harmless — and it deliberately does NOT undo a disconnect: if the owner
/// disconnected this Mac, the server keeps it disconnected and says so here.
final class DeviceRegistrar {
    static let shared = DeviceRegistrar()

    /// Stable per-install identifier. Held in UserDefaults rather than the
    /// Keychain on purpose: Keychain entries can outlive the app, and a
    /// reinstall SHOULD register as a new device with its own settings.
    private static let deviceIdKey = "clientDeviceId"
    /// The server's uuid for this device, learned at registration. Needed to
    /// push per-device wallpaper settings back up.
    private static let serverDeviceIdKey = "serverDeviceId"

    /// Set from the registration response. Plain property, not @Published —
    /// nothing observes it yet; make this ObservableObject when the UI needs it.
    private(set) var isDisconnected = false

    var serverDeviceId: String? { UserDefaults.standard.string(forKey: Self.serverDeviceIdKey) }

    private init() {}

    var clientDeviceId: String {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIdKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.deviceIdKey)
        return fresh
    }

    func registerIfNeeded() {
        guard AuthManager.shared.isLoggedIn else { return }

        // Physical pixels, which is what the wallpaper renderer needs — points
        // alone would produce a half-resolution image on a Retina display.
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 1
        let width = screen.map { Int($0.frame.width * scale) }
        let height = screen.map { Int($0.frame.height * scale) }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        var payload: [String: Any] = [
            "clientDeviceId": clientDeviceId,
            "platform": "macos",
            "deviceName": Host.current().localizedName ?? "Mac",
            "osVersion": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "scaleFactor": Double(scale)
        ]
        if let width { payload["screenWidth"] = width }
        if let height { payload["screenHeight"] = height }

        Task {
            do {
                let url = URL(string: "\(APIConfig.baseURL)/devices/register")!
                var request = AuthManager.shared.authenticatedRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                request.timeoutInterval = 20

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("[DeviceRegistrar] Registration failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                    return
                }

                // The server never resurrects a disconnected device, so this is
                // how the Mac finds out the owner switched it off.
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let device = json["data"] as? [String: Any] {
                    if let serverId = device["id"] as? String {
                        UserDefaults.standard.set(serverId, forKey: Self.serverDeviceIdKey)
                    }
                    let disconnected = !(device["disconnected_at"] is NSNull) && device["disconnected_at"] != nil
                    await MainActor.run { self.isDisconnected = disconnected }
                    print("[DeviceRegistrar] Registered as \(device["id"] ?? "?")\(disconnected ? " (DISCONNECTED by owner)" : "")")
                }
            } catch {
                print("[DeviceRegistrar] Registration error: \(error.localizedDescription)")
            }
        }
    }
}
