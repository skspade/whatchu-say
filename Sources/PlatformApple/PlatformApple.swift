import Foundation

/// Namespace marker for Apple-platform integrations.
///
/// Concrete implementations (HotkeySourceMac, InjectorMac, Overlay UI, etc.)
/// land in `Mac/` and `iOS/` subdirectories during Milestones 1.2–1.4.
public enum PlatformApple {
    public static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "unknown"
        #endif
    }
}
