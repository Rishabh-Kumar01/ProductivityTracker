import AppKit
import Combine
import SwiftUI

/// The full-screen sleep overlay on macOS.
///
/// One window per screen, because a single window leaves the second monitor
/// usable and the whole point is that the machine is away.
///
/// The window level sits above normal windows and above the menu bar, and it
/// joins every Space so switching desktops does not escape it. What it does NOT
/// do is claim to be unkillable: Force Quit removes it, and so does killing the
/// app. That gap is reported rather than papered over — the same treatment
/// `/etc/hosts` tampering already gets, and for the same reason. Pretending to
/// an enforcement guarantee that does not hold is worse than the gap itself.
@MainActor
final class SleepOverlayController {

    static let shared = SleepOverlayController()

    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?

    var isVisible: Bool { !windows.isEmpty }

    private init() {}

    func show() {
        guard windows.isEmpty else { return }
        build()

        // Monitors get plugged in. Without this a second screen attached after
        // the overlay went up would be an uncovered one.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard SleepOverlayController.shared.isVisible else { return }
                SleepOverlayController.shared.rebuild()
            }
        }
    }

    private func rebuild() {
        teardownWindows()
        build()
    }

    private func build() {
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // .screenSaver: above the menu bar, the Dock and ordinary windows,
            // which is what "the machine is away" requires.
            //
            // Deliberately NOT the maximum window level. Higher than this sits
            // over system-modal prompts — an authentication sheet, a disk or
            // battery warning — and covering something the OS needs him to
            // answer is a worse failure than an escapable overlay. The escape
            // hatch is the button, not a stacking accident.
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,      // switching Space does not escape it
                .fullScreenAuxiliary,   // nor does a full-screen app
                .stationary,
                .ignoresCycle
            ]
            window.isOpaque = true
            window.backgroundColor = NSColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1)
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.contentView = NSHostingView(rootView: SleepOverlayView())
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        teardownWindows()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    private func teardownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }
}

/// What he sees. Deliberately plain: this is not a screen to interact with,
/// apart from the one door out of it.
private struct SleepOverlayView: View {
    @ObservedObject private var sleep = SleepManager.shared
    @State private var now = Date()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Asleep")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(red: 0.545, green: 0.576, blue: 1.0))

            Text("The Mac is away until morning.")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 12)

            Text(remaining)
                .font(.system(size: 16))
                .foregroundColor(Color(white: 0.68))
                .padding(.top, 10)

            if sleep.escapesLeft > 0 {
                Button(action: { sleep.takeEscape() }) {
                    Text(sleep.isBusy
                         ? "…"
                         : "I need \(sleep.escapeMinutes) minutes  ·  \(sleep.escapesLeft) left")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sleep.isBusy)
                .padding(.top, 34)

                Text("You will be asked to explain it tomorrow.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.top, 10)
            } else {
                Text("No more escapes tonight.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.top, 30)
            }

            if let error = sleep.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.top, 10)
            }

            Spacer()

            Text("Quitting the app removes this. She is told when that happens.")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.32))
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(tick) { now = $0 }
    }

    /// Rendered locally from one timestamp, like every other clock here.
    private var remaining: String {
        guard let wakes = sleep.wakesAt else { return "Until your waking time" }
        let left = wakes.timeIntervalSince(now)
        if left <= 0 { return "Ending…" }
        let hours = Int(left) / 3600
        let minutes = (Int(left) % 3600) / 60
        return String(format: "%dh %02dm until morning", hours, minutes)
    }
}
