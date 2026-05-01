import Foundation

public protocol Injector: Sendable {
    func inject(text: String, hint: InjectionHint) async throws
}

public enum InjectionHint: Sendable, Equatable {
    case auto
    case forceType
    case forcePaste
}
