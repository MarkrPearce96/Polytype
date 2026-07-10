import Foundation

/// Wraps a primary engine (Google) with the monthly free-tier cap. Under the
/// cap it translates and records the characters; over it, it throws
/// `.quotaExceeded` so `FallbackChain` uses the (free) Apple fallback — the user
/// can never be charged for over-quota Google usage.
public final class QuotaGate: TranslationEngine {
    private let primary: TranslationEngine
    private let meter: UsageMeter

    public init(primary: TranslationEngine, meter: UsageMeter) {
        self.primary = primary
        self.meter = meter
    }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let chars = text.unicodeScalars.count
        guard meter.canUseGoogle(adding: chars) else { throw TranslationError.quotaExceeded }
        let result = try await primary.translate(text, from: source, to: target)   // network error propagates
        meter.record(chars)                                                        // only on success
        return result
    }
}
