import Foundation
import os

public enum LogSubsystem: String, Sendable {
    case audio
    case stt
    case hotkey
    case injector
    case orchestrator
    case usage
    case overlay
    case ui
    case config
}

public enum AppLogger {
    public static let bundleID = "com.whatchu-say"

    public static func logger(for subsystem: LogSubsystem) -> Logger {
        Logger(subsystem: bundleID, category: subsystem.rawValue)
    }
}
