import Foundation
import CoreGraphics

enum IdleWatcher {
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!) // NOTE: ~0 is the documented kCGAnyInputEventType sentinel; if this init ever returns nil on a future SDK, fall back to the min over .keyDown/.mouseMoved/.leftMouseDown/.scrollWheel.
    }
}
