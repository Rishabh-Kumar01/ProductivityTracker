import Foundation
import AppKit
import CoreImage
import Combine

/// Applies the partner's chosen image as this Mac's desktop wallpaper.
///
/// The server stores ONE original. Every device renders it locally at its own
/// exact pixel size, which is why nothing here asks the server for a resized
/// copy: this Mac knows its screens better than the server ever could.
///
/// Brightness and contrast are the owner's, per device, and are applied here
/// rather than baked into the stored image — so changing them is instant and
/// never touches what she uploaded.
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    /// 0 = black, 1 = untouched. Multiplicative, matching Android's ColorMatrix
    /// `setScale` so both devices agree on what "50%" means.
    @Published var brightness: Double = UserDefaults.standard.object(forKey: "wallpaperBrightness") as? Double ?? 1.0
    /// 1 = untouched. Pivots around mid-grey.
    @Published var contrast: Double = UserDefaults.standard.object(forKey: "wallpaperContrast") as? Double ?? 1.0

    private var enforceTimer: Timer?
    private let ciContext = CIContext()   // Metal-backed on Apple Silicon
    /// What we last set, per display. Enforcement compares against this.
    private var appliedURLs: [CGDirectDisplayID: URL] = [:]
    private var lastSourceData: Data?
    /// Switching Spaces makes the desktop legitimately show a different
    /// wallpaper until we claim that Space. Without this, enforce() would read
    /// every switch as "he changed it" and mail her each time.
    private var lastSpaceChange: Date?

    /// macOS 14+ renders the desktop from com.apple.wallpaper's store, NOT from
    /// the legacy desktoppicture.db that `setDesktopImageURL` writes to. The
    /// legacy getter therefore reads back whatever we just wrote and always
    /// agrees with us — it cannot detect failure. This file is the only place
    /// that reflects what is actually on screen.
    private var renderStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    }

    /// File paths appear inside binary configuration blobs, so this is a byte
    /// search rather than a plist walk — the nested format is undocumented and
    /// version-specific, the bytes are not.
    private func renderStoreContains(_ filename: String) -> Bool {
        guard let data = try? Data(contentsOf: renderStoreURL),
              let needle = filename.data(using: .utf8) else { return false }
        return data.range(of: needle) != nil
    }

    /// WallpaperAgent can sit in a state where it ignores legacy writes entirely.
    /// Restarting it makes it re-read them. Crude, but it is the difference
    /// between the wallpaper changing and silently not changing.
    private func nudgeWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
    }

    private var wallpaperDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProductivityTracker/Wallpapers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        refresh()

        // Neither macOS nor AppKit notifies on wallpaper change, so this polls.
        enforceTimer?.invalidate()
        enforceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.enforce()
        }
        enforceTimer?.tolerance = 5

        // A new monitor has its own resolution and needs its own render.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyToAllScreens(reason: "screen config changed")
        }

        // macOS wallpapers are per-Space, and `setDesktopImageURL` only ever
        // touches the Space that is active when it runs — so on a Mac with ten
        // Spaces, nine of them keep whatever was there before. Re-applying on
        // every switch means each Space is claimed the first time it is used.
        // (System Settings' "Show on all Spaces" does it in one go, but that is
        // a user preference we cannot set.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastSpaceChange = Date()
            self?.applyToAllScreens(reason: "space switch")
        }
    }

    func stop() {
        enforceTimer?.invalidate()
        enforceTimer = nil
    }

    // MARK: - Owner adjustment

    func setAdjustment(brightness: Double, contrast: Double) {
        self.brightness = min(max(brightness, 0), 1)
        self.contrast = min(max(contrast, 0), 3)
        UserDefaults.standard.set(self.brightness, forKey: "wallpaperBrightness")
        UserDefaults.standard.set(self.contrast, forKey: "wallpaperContrast")
        applyToAllScreens(reason: "brightness/contrast changed")
        pushSettingsToServer()
    }

    /// Reported so the partner can see what it was dimmed to. She cannot change
    /// it — visibility instead of restriction, by design.
    private func pushSettingsToServer() {
        guard let deviceId = DeviceRegistrar.shared.serverDeviceId,
              AuthManager.shared.isLoggedIn,
              let url = URL(string: "\(APIConfig.baseURL)/devices/\(deviceId)/wallpaper-settings")
        else { return }

        Task {
            var request = AuthManager.shared.authenticatedRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["brightness": brightness, "contrast": contrast]
            )
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code != 200 { print("[Wallpaper] settings report rejected: HTTP \(code)") }
            } catch {
                print("[Wallpaper] settings report failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Fetch

    /// Pulls the current customization and re-applies. Called at start and on
    /// the `customization_updated` SSE event.
    func refresh() {
        guard AuthManager.shared.isLoggedIn else { return }

        Task {
            do {
                let url = URL(string: "\(APIConfig.baseURL)/customization")!
                let (data, response) = try await URLSession.shared.data(
                    for: AuthManager.shared.authenticatedRequest(url: url)
                )
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = json["data"] as? [String: Any] else { return }

                if let background = payload["background"] as? [String: Any],
                   let imageURLString = background["url"] as? String,
                   let imageURL = URL(string: imageURLString) {
                    let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                    await MainActor.run {
                        self.lastSourceData = imageData
                        self.applyToAllScreens(reason: "image changed")
                    }
                } else {
                    // Cleared. Spec: natives go solid black rather than
                    // restoring whatever was there before.
                    await MainActor.run {
                        self.lastSourceData = nil
                        self.applyToAllScreens(reason: "background cleared")
                    }
                }
            } catch {
                print("[Wallpaper] refresh failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Render & apply

    private func applyToAllScreens(reason: String = "unspecified") {
        print("[Wallpaper] applying (\(reason))")
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }

            let pixelSize = CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )

            guard let cgImage = renderImage(for: pixelSize) else { continue }

            // macOS caches the wallpaper by URL: overwriting the same path does
            // not refresh the desktop. Each render gets a fresh filename, and
            // the previous one is removed afterwards.
            let target = wallpaperDir.appendingPathComponent("\(displayID)-\(UUID().uuidString.prefix(8)).jpg")
            guard writeJPEG(cgImage, to: target) else { continue }

            do {
                try NSWorkspace.shared.setDesktopImageURL(target, for: screen, options: [:])
                let previous = appliedURLs[displayID]
                appliedURLs[displayID] = target
                if let previous { try? FileManager.default.removeItem(at: previous) }
            } catch {
                print("[Wallpaper] setDesktopImageURL failed: \(error.localizedDescription)")
            }
        }

        verifyApplied()
    }

    /// `setDesktopImageURL` returning without error means nothing on macOS 14+.
    /// Check the render store, and if the write did not land, restart the agent
    /// and check again before giving up.
    private func verifyApplied(retrying: Bool = true) {
        guard let expected = appliedURLs.values.first?.lastPathComponent else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self else { return }
            if self.renderStoreContains(expected) {
                // Confirmed on screen — tell the server, which stamps
                // wallpaper_applied_at so the partner can see it landed.
                self.pushSettingsToServer()
                return
            }

            guard retrying else {
                print("[Wallpaper] render store still does not reference \(expected) — wallpaper is NOT applied")
                return
            }
            print("[Wallpaper] write did not reach the render store — restarting WallpaperAgent")
            self.nudgeWallpaperAgent()

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self else { return }
                for screen in NSScreen.screens {
                    guard let displayID = screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                    ] as? CGDirectDisplayID, let url = self.appliedURLs[displayID] else { continue }
                    try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
                self.verifyApplied(retrying: false)
            }
        }
    }

    /// Aspect-fill the source to `size`, then apply the owner's adjustment.
    /// With no image set, produces solid black at the same size.
    private func renderImage(for size: CGSize) -> CGImage? {
        guard let data = lastSourceData, let source = CIImage(data: data) else {
            return solidBlack(size: size)
        }

        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return solidBlack(size: size) }

        // Fill, not fit: a desktop should never letterbox. The blurred-edge
        // treatment is the browser's job, where the whole photo must stay visible.
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropOrigin = CGPoint(
            x: scaled.extent.origin.x + (scaled.extent.width - size.width) / 2,
            y: scaled.extent.origin.y + (scaled.extent.height - size.height) / 2
        )
        let cropped = scaled.cropped(to: CGRect(origin: cropOrigin, size: size))

        // out = in * (contrast * brightness) + (0.5 - 0.5 * contrast) * brightness
        // Contrast pivots around mid-grey, brightness multiplies. Expressed as a
        // single matrix so Android can reproduce it with identical numbers.
        let s = CGFloat(contrast * brightness)
        let bias = CGFloat((0.5 - 0.5 * contrast) * brightness)
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(cropped, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: s, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: s, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: s, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: CGRect(origin: cropOrigin, size: size))
    }

    /// Tells the server the wallpaper was replaced. The server always audits it
    /// and emails the partner at most once per device per hour, so this can be
    /// called on every detection without worrying about flooding her.
    private func reportReverted() {
        guard let deviceId = DeviceRegistrar.shared.serverDeviceId,
              AuthManager.shared.isLoggedIn,
              let url = URL(string: "\(APIConfig.baseURL)/devices/\(deviceId)/wallpaper-reverted")
        else { return }

        Task {
            var request = AuthManager.shared.authenticatedRequest(url: url)
            request.httpMethod = "POST"
            do {
                var (_, response) = try await URLSession.shared.data(for: request)
                var code = (response as? HTTPURLResponse)?.statusCode ?? -1

                // A stale access token would otherwise drop the report on the
                // floor. SyncManager already refreshes and retries on 401; this
                // has to do the same or reverts go unrecorded whenever the token
                // happens to have expired.
                if code == 401 {
                    try await AuthManager.shared.refreshAccessToken()
                    request = AuthManager.shared.authenticatedRequest(url: url)
                    request.httpMethod = "POST"
                    (_, response) = try await URLSession.shared.data(for: request)
                    code = (response as? HTTPURLResponse)?.statusCode ?? -1
                }

                if code == 200 {
                    print("[Wallpaper] revert reported to server")
                } else {
                    print("[Wallpaper] revert report rejected: HTTP \(code)")
                }
            } catch {
                print("[Wallpaper] revert report failed: \(error.localizedDescription)")
            }
        }
    }

    private func solidBlack(size: CGSize) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: rect)
        return ciContext.createCGImage(black, from: rect)
    }

    private func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            print("[Wallpaper] write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Enforcement

    /// Re-applies if the wallpaper was changed behind our back. macOS has no
    /// change notification, so this is a poll.
    private func enforce() {
        guard lastSourceData != nil || !appliedURLs.isEmpty else { return }

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID,
                  let expected = appliedURLs[displayID] else { continue }

            // Both are checked: the legacy value catches a deliberate change by
            // the owner, the render store catches a write that never landed.
            let legacy = NSWorkspace.shared.desktopImageURL(for: screen)
            if legacy != expected || !renderStoreContains(expected.lastPathComponent) {
                let afterSpaceSwitch = lastSpaceChange.map { Date().timeIntervalSince($0) < 15 } ?? false
                print("[Wallpaper] wallpaper is not ours — re-applying\(afterSpaceSwitch ? " (space switch, not reporting)" : "")")
                applyToAllScreens(reason: "enforcement")
                // Only a change on a Space we had already claimed is the owner
                // actually replacing it; a fresh Space is just a fresh Space.
                if !afterSpaceSwitch { reportReverted() }
                return
            }
        }
    }
}
