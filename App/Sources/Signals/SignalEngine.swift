import AppKit
import ClocktopusCore

@MainActor
final class SignalEngine {
    private unowned let state: AppState
    private let appObserver = AppObserver()
    private var timer: Timer?
    private var browserTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastBrowserURL: String?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fast path for in-browser navigation: the 30s tick can lag a tab
        // change by up to 30s, so poll the URL more often and fire a full
        // observation only when it actually changed.
        browserTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.browserTick() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        browserTimer?.invalidate()
        browserTimer = nil
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Cheap URL-only check; when the active tab changed, fire a full tick so
    /// the navigation is captured promptly instead of waiting for the 30s tick.
    private func browserTick() {
        guard state.browserDetectionEnabled else { return }
        let bundleId = appObserver.frontmostBundleId
        guard BrowserProber.isBrowser(bundleId) else { return }
        if BrowserProber.activeTabURL(frontmostBundleId: bundleId) != lastBrowserURL {
            tick()
        }
    }

    private func tick() {
        let bundleId = appObserver.frontmostBundleId
        let terminalPid = AppObserver.isTerminalApp(bundleId) ? appObserver.frontmostPid : nil
        let aiTools = state.effectiveAITools

        var dirs = ShellProber.probe(aiTools: aiTools, frontmostTerminalPid: terminalPid)
        dirs += TmuxProber.probe()

        var activeTabURL: String?
        if state.browserDetectionEnabled, BrowserProber.isBrowser(bundleId) {
            activeTabURL = BrowserProber.activeTabURL(frontmostBundleId: bundleId)
        }
        lastBrowserURL = activeTabURL   // keep the fast poll in sync so it doesn't double-fire

        // Don't record ourselves as evidence — the Review window being
        // frontmost shouldn't show up as "Clocktopus".
        let appName = bundleId == Bundle.main.bundleIdentifier ? nil : appObserver.frontmostAppName

        let observation = Observation(
            timestamp: Date(),
            frontmostApp: bundleId,
            windowTitle: appObserver.windowTitle(),
            dirs: dirs,
            idleSeconds: IdleWatcher.idleSeconds(),
            activeTabURL: activeTabURL,
            frontmostAppName: appName)
        state.handle(observation: observation)
    }
}
