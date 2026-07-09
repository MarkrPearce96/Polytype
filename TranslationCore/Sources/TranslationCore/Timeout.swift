import Foundation

/// Races a cancellable `operation` against a timeout, returning whichever finishes
/// first.
///
/// This is the right tool specifically when `operation` is cancellation-aware (it
/// either checks `Task.isCancelled` itself, or calls into an API that does — e.g.
/// `Task.sleep`, `URLSession`, or Apple's `TranslationSession.translate`). When the
/// timeout wins, the losing `operation` task is cancelled via `group.cancelAll()`,
/// and because it observes cancellation, it actually unwinds rather than lingering as
/// an orphaned awaiter.
///
/// Contrast with `ResumeOnceGate`, which exists for the *harder* case: racing a
/// timeout against a producer that has no cancellation hook at all (e.g. a bare
/// `withCheckedContinuation` that only its producer can resume). Racing that kind of
/// producer with this function would not work — `cancelAll()` cannot unblock an
/// awaiter that never checks for cancellation, so the loser would hang forever and
/// the timeout would never actually free the caller.
///
/// - Parameters:
///   - seconds: how long to wait before considering `operation` timed out.
///   - onTimeout: builds the error to throw if the timeout elapses first.
///   - operation: the cancellable work to race against the timeout.
/// - Returns: `operation`'s result, if it finished before the timeout.
/// - Throws: `operation`'s error if it throws first; otherwise `onTimeout()`'s error
///   once `seconds` elapses first.
func withTimeout<Value: Sendable>(
    seconds: Duration,
    onTimeout: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: seconds)
            throw onTimeout()
        }
        do {
            let result = try await group.next()!
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}
