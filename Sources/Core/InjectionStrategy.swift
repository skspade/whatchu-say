import Foundation

/// User-selectable injection strategy persisted in `AppConfig`.
///
/// Lives in `Core` (not `Injector`) because `AppConfig` and `ConfigStore`
/// reference it, and `Core` cannot depend on `Injector`.
public enum InjectionStrategy: String, Codable, Sendable, Equatable {
    case auto
    case type
    case paste
}
