import AppKit

/// Flips the app between accessory (menubar-only) and regular activation
/// policy so Review/Preferences are reachable via cmd-tab while open.
///
/// An LSUIElement app is never listed in the app switcher, so once its window
/// falls behind another app there is no way back to it except the menubar.
/// While a managed window is open we run as a regular app (cmd-tab + Dock
/// icon); when the last one closes we return to accessory so the app is
/// menubar-only again. The two are one switch — cmd-tab presence without a
/// Dock icon is not possible.
@MainActor
final class WindowPolicy {
    static let shared = WindowPolicy()
    private var observer: NSObjectProtocol?
    private static let presentationAttempts = 4

    /// Dismiss the menubar popover, open (or reuse) a managed SwiftUI scene,
    /// and raise it once SwiftUI has materialized its NSWindow.
    func present(id: String, openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        if let keyWindow = NSApp.keyWindow, !Self.isManaged(keyWindow) {
            keyWindow.orderOut(nil)
        }

        if let window = Self.managedWindow(id: id, among: NSApp.windows) {
            Self.bringToFront(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openWindow()
        focusWhenAvailable(id: id, attemptsRemaining: Self.presentationAttempts)
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                Self.shared.windowWillClose(closing)
            }
        }
    }

    private func windowWillClose(_ closing: NSWindow) {
        guard Self.isManaged(closing) else { return }
        // The closing window is still visible at willClose time — look for
        // any *other* managed window before dropping back to accessory.
        let stillOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && Self.isManaged($0)
        }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func managedWindow(id: String, among windows: [NSWindow]) -> NSWindow? {
        windows.first { matches($0, id: id) }
    }

    static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func focusWhenAvailable(id: String, attemptsRemaining: Int) {
        if let window = Self.managedWindow(id: id, among: NSApp.windows) {
            Self.bringToFront(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard attemptsRemaining > 0 else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusWhenAvailable(id: id, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    /// The Review and Preferences windows — not the menubar popover or panels.
    /// SwiftUI derives the NSWindow identifier from the scene id; match the
    /// title as a fallback in case that changes.
    private static func isManaged(_ window: NSWindow) -> Bool {
        matches(window, id: "review") || matches(window, id: "preferences")
    }

    private static func matches(_ window: NSWindow, id: String) -> Bool {
        if window.identifier?.rawValue.hasPrefix(id) == true { return true }
        let title = id == "review" ? "Clocktopus Review" : "Clocktopus Preferences"
        return window.title == title
    }
}
