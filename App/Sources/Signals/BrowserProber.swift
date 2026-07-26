import Foundation

/// Reads the active tab URL of the frontmost browser via Apple Events. Only
/// scriptable browsers are supported; anything else returns nil silently. The
/// caller gates this behind a user setting, and the first call per browser
/// triggers the macOS Automation permission prompt.
enum BrowserProber {
    /// Bundle id → AppleScript source. Targeting `application id` avoids
    /// depending on the app's display name. Safari uses `current tab`; the
    /// Chromium family uses `active tab`.
    private static let scripts: [String: String] = [
        "com.apple.Safari":
            "tell application id \"com.apple.Safari\" to return URL of current tab of front window",
        "com.google.Chrome":
            "tell application id \"com.google.Chrome\" to return URL of active tab of front window",
        "com.brave.Browser":
            "tell application id \"com.brave.Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac":
            "tell application id \"com.microsoft.edgemac\" to return URL of active tab of front window",
        "company.thebrowser.Browser":
            "tell application id \"company.thebrowser.Browser\" to return URL of active tab of front window",
    ]

    static func isBrowser(_ bundleId: String?) -> Bool {
        bundleId.map { scripts[$0] != nil } ?? false
    }

    /// Active tab URL of the frontmost browser, or nil when it isn't a known
    /// browser, permission was denied, or there's no front window. Must run on
    /// the main thread (an `NSAppleScript` requirement).
    static func activeTabURL(frontmostBundleId: String?) -> String? {
        guard let id = frontmostBundleId, let source = scripts[id],
              let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let url = result.stringValue, !url.isEmpty else { return nil }
        return url
    }
}
