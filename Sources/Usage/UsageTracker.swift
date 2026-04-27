import Foundation

/// Tracks per-session usage and computes daily/monthly aggregates.
/// Stub: persistence + cost estimation lands in Milestone 1.5.
public actor UsageTracker {
    private var totalSeconds: UInt64 = 0
    private var sessionCount: UInt64 = 0

    public init() {}

    public func recordSession(durationMs: UInt64, provider: String) async {
        totalSeconds += durationMs / 1000
        sessionCount += 1
    }

    public func snapshot() -> UsageSnapshot {
        UsageSnapshot(totalSeconds: totalSeconds, sessionCount: sessionCount)
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let totalSeconds: UInt64
    public let sessionCount: UInt64
}
