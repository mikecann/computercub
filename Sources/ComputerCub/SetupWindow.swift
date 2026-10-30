import AppKit
import ApplicationServices
import ComputerCubCore
import SwiftUI

// The setup window, after RememBear's: a row per permission that goes red to green
// by itself, and a button that opens the right part of System Settings.

/// Reads where each permission stands, and asks for them.
enum Permissions {
    static func current() -> SetupState {
        SetupState(accessibility: AXIsProcessTrusted() ? .granted : .missing,
                   screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .missing)
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Saying Later while only Screen Recording is missing stops the window opening by
/// itself for that alone; screenshots are optional.
enum SetupPrefs {
    static let skippedScreenRecordingKey = "skippedScreenRecording"
    static var skippedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: skippedScreenRecordingKey) }
        set { UserDefaults.standard.set(newValue, forKey: skippedScreenRecordingKey) }
    }
}

/// Keeps the window's state fresh: macOS sends no notice when a permission is
/// switched on, so it looks again every second while the window is open.
final class SetupModel: ObservableObject {
    @Published var state = Permissions.current()
    /// Screen Recording only takes in a process started after it's turned on.
    @Published var askedForScreen = false
    private var timer: Timer?

    func start() {
        refresh()
        // Scheduled on the main run loop, so it refreshes on the main thread.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let now = Permissions.current()
        if now != state { state = now }
    }

    func allowAccessibility() {
        // Asking also puts ComputerCub in the list, so there's something to switch on.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        Permissions.openSettings("Privacy_Accessibility")
    }

    func allowScreen() {
        askedForScreen = true
        SetupPrefs.skippedScreenRecording = false
        // The first time this shows macOS's own prompt; after that it does nothing,
        // so the Settings pane opens too.
        CGRequestScreenCaptureAccess()
        Permissions.openSettings("Privacy_ScreenCapture")
    }

    /// Opens a new copy once this one has quit, so a Screen Recording grant takes.
    func restart() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -a \"$0\" --args serve", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let close: () -> Void

    var body: some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.headline).font(.title3.weight(.semibold))
                    Text(s.subline).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                PermissionRow(state: s.accessibility, title: "Accessibility",
                              why: "Reads windows and presses things for your agents. Nothing works without it.",
                              action: model.allowAccessibility)
                Divider()
                PermissionRow(state: s.screenRecording, title: "Screen Recording",
                              why: "Only for screenshots of one window. Optional, and they never leave this Mac.",
                              action: model.allowScreen)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if model.askedForScreen && s.screenRecording != .granted {
                    Button("Restart ComputerCub", action: model.restart)
                        .help("Screen Recording only takes after a restart")
                }
                Spacer()
                Button(s.isComplete ? "Done" : "Later") {
                    // Later with only screenshots missing: don't open again just for that.
                    if s.isReady && !s.isComplete { SetupPrefs.skippedScreenRecording = true }
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

private struct PermissionRow: View {
    let state: PermissionState
    let title: String
    let why: String
    let action: () -> Void

    var body: some View {
        let on = state == .granted
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(on ? Color.green : Color.red)
                .frame(width: 11, height: 11)
                .animation(.easeOut(duration: 0.25), value: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on {
                Image(systemName: "checkmark").foregroundStyle(.green).font(.body.weight(.semibold))
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// ComputerCub has no Dock icon or menu, so the window comes back when the app is
/// opened again (a double-click while it's running) or with `computercub setup`.
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?
    private let model = SetupModel()

    /// At launch: only when something's missing (see SetupState.opensAtLaunch).
    func showIfNeeded() {
        if Permissions.current().opensAtLaunch(skippedScreenRecording: SetupPrefs.skippedScreenRecording) { show() }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: model) { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: host)
            w.title = "ComputerCub"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Show up on the Space Mike is looking at, not wherever the app last was.
            w.collectionBehavior = [.moveToActiveSpace]
            w.delegate = self
            w.center()
            window = w
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

/// Opening ComputerCub.app while it's already running brings the setup window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SetupWindowController.shared.show()
        return false
    }
}
