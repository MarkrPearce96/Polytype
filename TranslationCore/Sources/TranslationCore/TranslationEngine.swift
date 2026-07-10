import Foundation

/// A source of `source`→`target` translation. Implementations must be safe to call
/// concurrently and must throw `TranslationError` on failure.
public protocol TranslationEngine: Sendable {
    /// Translate `text` from `source` into `target` (e.g. "en", "zh-TW"). Throws on failure.
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

public enum TranslationError: Error, Equatable, Sendable {
    case noAPIKey
    case quotaExceeded
    case network(String)
    case http(Int)
    case empty
}
