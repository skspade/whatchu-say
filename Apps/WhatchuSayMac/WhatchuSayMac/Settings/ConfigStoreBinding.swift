import SwiftUI
import Core

/// SwiftUI binding helpers on `ConfigStore`. Lives in the Mac app target
/// (not `Core`) so `Core` stays SwiftUI-free.
///
/// `ConfigStore.config` is `private(set)` and the canonical mutation API is
/// `update { $0.field = value }`. These helpers wrap a `KeyPath` into a
/// `Binding` so SwiftUI controls (`Toggle`, `Picker`, `TextField`) can speak
/// to nested fields directly without callers writing the closure shape by
/// hand.
extension ConfigStore {
    /// Two-way binding for any field reachable from `AppConfig` via a writable key path.
    func binding<Value>(for keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in
                self.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// Same as `binding(for:)`, but invokes `onSet` after the config write.
    /// Useful for fields that drive a side effect (e.g., launch-at-login
    /// toggling SMAppService registration). The side effect runs on the
    /// MainActor since `ConfigStore` is MainActor-isolated.
    func binding<Value>(
        for keyPath: WritableKeyPath<AppConfig, Value>,
        onSet: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in
                self.update { $0[keyPath: keyPath] = newValue }
                onSet(newValue)
            }
        )
    }
}
