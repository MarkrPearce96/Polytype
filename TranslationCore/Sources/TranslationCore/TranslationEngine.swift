import Foundation

/// A source of English→target translation. Implementations must be safe to call
/// concurrently and must throw `TranslationError` on failure.
public protocol TranslationEngine: Sendable {
    /// Translate `english` into `target` (e.g. "zh-TW"). Throws on failure.
    func translate(_ english: String, to target: String) async throws -> String
}

public enum TranslationError: Error, Equatable, Sendable {
    case noAPIKey
    case quotaExceeded
    case network(String)
    case http(Int)
    case empty
}
