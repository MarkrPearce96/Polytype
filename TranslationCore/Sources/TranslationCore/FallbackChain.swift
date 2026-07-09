import Foundation

/// Tries `primary`; on any `TranslationError`, reports the reason and tries `fallback`.
public final class FallbackChain: TranslationEngine, @unchecked Sendable {
    private let primary: TranslationEngine
    private let fallback: TranslationEngine
    public var onFallback: (@Sendable (TranslationError) -> Void)?

    public init(primary: TranslationEngine, fallback: TranslationEngine) {
        self.primary = primary; self.fallback = fallback
    }

    public func translate(_ english: String, to target: String) async throws -> String {
        do {
            return try await primary.translate(english, to: target)
        } catch let error as TranslationError {
            onFallback?(error)
            return try await fallback.translate(english, to: target)
        }
    }
}
