import Foundation
import Observation

/// Sendable read/write surface for persisting `AppConfig`. Default impl is
/// `UserDefaultsConfigPersistence`; tests use `InMemoryConfigPersistence`.
///
/// Both methods are synchronous — `UserDefaults` is documented thread-safe
/// and the in-memory impl serializes through a lock — so callers don't need
/// to hop actors just to save.
public protocol ConfigPersistence: Sendable {
    func load() -> Data?
    func save(_ data: Data)
    /// Stash a blob that couldn't be decoded before it's overwritten with
    /// defaults, so it can be recovered by hand.
    func backup(_ data: Data)
}

extension ConfigPersistence {
    public func backup(_ data: Data) {}
}

/// `@unchecked Sendable` because `UserDefaults` is documented thread-safe but
/// not formally `Sendable` in the Swift 6 stdlib.
public struct UserDefaultsConfigPersistence: ConfigPersistence, @unchecked Sendable {
    public static let defaultKey = "WhatchuSayAppConfig"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsConfigPersistence.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Data? {
        defaults.data(forKey: key)
    }

    public func save(_ data: Data) {
        defaults.set(data, forKey: key)
    }

    /// Stored under `<key>.backup`; recover with
    /// `defaults read <bundle-id> <key>.backup`.
    public func backup(_ data: Data) {
        defaults.set(data, forKey: "\(key).backup")
    }
}

/// In-memory persistence for tests. Thread-safe via `NSLock`.
public final class InMemoryConfigPersistence: ConfigPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var backupData: Data?

    public init(initial: Data? = nil) {
        self.data = initial
    }

    public func load() -> Data? {
        lock.withLock { data }
    }

    public func save(_ data: Data) {
        lock.withLock { self.data = data }
    }

    public func backup(_ data: Data) {
        lock.withLock { backupData = data }
    }

    /// Test-only inspection of the most recently saved blob.
    public var snapshot: Data? {
        lock.withLock { data }
    }

    /// Test-only inspection of the most recently backed-up blob.
    public var backupSnapshot: Data? {
        lock.withLock { backupData }
    }
}

/// Single source of truth for `AppConfig`. SwiftUI views observe via
/// `@Observable`; mutations debounce a JSON write to `persistence`.
///
/// Lifecycle:
/// - On init, `persistence.load()` is decoded via `ConfigMigration`.
///   - Config written by a *newer* build (`unsupportedSchemaVersion`, e.g.
///     running an older branch): run on defaults in memory and never write,
///     so the newer build still finds its settings.
///   - Corrupt blob: back it up via `persistence.backup`, then write
///     defaults so subsequent loads succeed.
/// - `update { ... }` mutates the in-memory config and schedules a save
///   ~250 ms later. Successive calls coalesce — only the latest snapshot
///   reaches disk.
/// - `flush()` forces an immediate save, bypassing the debounce. Use on
///   app termination and in tests.
@MainActor
@Observable
public final class ConfigStore {
    public private(set) var config: AppConfig

    @ObservationIgnored
    private let persistence: any ConfigPersistence
    @ObservationIgnored
    private let saveDebounce: Duration
    @ObservationIgnored
    private var pendingSave: Task<Void, Never>?
    /// True when the stored config came from a newer build. Changes stay in
    /// memory for this session instead of overwriting it.
    @ObservationIgnored
    private var persistenceSuspended = false

    private static let log = AppLogger.logger(for: .config)

    public init(
        persistence: any ConfigPersistence = UserDefaultsConfigPersistence(),
        saveDebounce: Duration = .milliseconds(250)
    ) {
        self.persistence = persistence
        self.saveDebounce = saveDebounce

        if let data = persistence.load() {
            do {
                self.config = try ConfigMigration.migrate(data)
                return
            } catch ConfigMigrationError.unsupportedSchemaVersion(let version) {
                Self.log.error("config schema \(version) is newer than this build supports; using defaults without saving")
                self.config = AppConfig()
                self.persistenceSuspended = true
                return
            } catch {
                Self.log.error("config decode failed; backing up and writing defaults: \(String(describing: error))")
                persistence.backup(data)
            }
        }

        self.config = AppConfig()
        Self.persist(config, to: persistence)
    }

    /// Mutate the config and schedule a debounced save.
    public func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        scheduleSave()
    }

    /// Force an immediate, synchronous save. Cancels any pending debounced save.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !persistenceSuspended else { return }
        Self.persist(config, to: persistence)
    }

    private func scheduleSave() {
        guard !persistenceSuspended else { return }
        pendingSave?.cancel()
        let snapshot = config
        let persistence = self.persistence
        let debounce = self.saveDebounce
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            Self.persist(snapshot, to: persistence)
            await MainActor.run { self?.pendingSave = nil }
        }
    }

    private static func persist(_ config: AppConfig, to persistence: any ConfigPersistence) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(config)
            persistence.save(data)
        } catch {
            log.error("config encode failed: \(String(describing: error))")
        }
    }
}
