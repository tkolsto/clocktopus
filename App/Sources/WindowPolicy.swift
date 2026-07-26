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

    /// Call before activating the app to open a managed window.
    func willOpenWindow() {
        NSApp.setActivationPolicy(.regular)
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

    /// The Review and Preferences windows — not the menubar popover or panels.
    /// SwiftUI derives the NSWindow identifier from the scene id; match the
    /// title as a fallback in case that changes.
    private static func isManaged(_ window: NSWindow) -> Bool {
        if let id = window.identifier?.rawValue,
           id.hasPrefix("review") || id.hasPrefix("preferences") {
            return true
        }
        return window.title == "Clocktopus Review"
            || window.title == "Clocktopus Preferences"
    }
}
