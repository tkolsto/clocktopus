import AppKit
import ApplicationServices

final class AppObserver {
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
    ]

    var frontmostBundleId: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var frontmostPid: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func isTerminalApp(_ bundleId: String?) -> Bool {
        bundleId.map { terminalBundleIds.contains($0) } ?? false
    }

    /// Focused window title via Accessibility. Returns nil without the
    /// permission — callers degrade gracefully per spec.
    func windowTitle() -> String? {
        guard let pid = frontmostPid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXTitleAttribute as CFString,
                                            &title) == .success else { return nil }
        return title as? String
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
