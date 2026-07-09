import Foundation

/// Resumes a single asynchronous result exactly once, whichever of two racing paths —
/// a "producer" with no cancellation hook, or a timeout — completes first, and
/// guarantees the awaiting call can never hang.
///
/// This exists because racing `Task.sleep` against a bare `withCheckedContinuation`
/// inside a `withThrowingTaskGroup` does NOT work: when the timeout wins,
/// `group.cancelAll()` cannot unblock a continuation-based awaiter that isn't itself
/// cancellation-aware, so if the producer never fires, the whole group (and anything
/// awaiting it) hangs forever. `ResumeOnceGate` avoids that failure mode entirely by
/// holding a single continuation and letting either the producer or the timeout
/// resume it *directly* — there is never an orphaned awaiter to hang on.
///
/// Whichever of `resume(returning:)` / `resume(throwing:)` runs first wins; every
/// later call (including a "late" producer that fires after the timeout already won)
/// is a harmless no-op. Each instance is single-use: create a fresh gate per
/// operation, call `armTimeout` (optional) before `wait()`, then call `wait()` exactly
/// once.
actor ResumeOnceGate<Value> {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Value, Error>)
        case settled(Result<Value, Error>)
    }

    private var state: State = .pending
    private var timeoutTask: Task<Void, Never>?

    init() {}

    /// Arms a timeout that resumes this gate with `makeError()` after `duration`,
    /// unless the gate is resumed by something else first. Safe to call before or
    /// after `wait()`; if the gate is already settled when the timeout elapses, it is
    /// a no-op.
    func armTimeout(after duration: Duration, throwing makeError: @escaping @Sendable () -> Error) {
        timeoutTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.resume(throwing: makeError())
        }
    }

    /// Suspends until resumed by the producer or the armed timeout, whichever is
    /// first. If the gate is already settled, returns/throws immediately. Must not be
    /// called concurrently from more than one awaiter.
    func wait() async throws -> Value {
        switch state {
        case .settled(let result):
            return try result.get()
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                state = .waiting(continuation)
            }
        case .waiting:
            preconditionFailure("ResumeOnceGate.wait() must not be awaited concurrently")
        }
    }

    /// Resumes the gate with `value`. A no-op if the gate is already settled.
    func resume(returning value: Value) {
        settle(.success(value))
    }

    /// Resumes the gate with `error`. A no-op if the gate is already settled.
    func resume(throwing error: Error) {
        settle(.failure(error))
    }

    private func settle(_ result: Result<Value, Error>) {
        switch state {
        case .settled:
            return
        case .pending:
            state = .settled(result)
            timeoutTask?.cancel()
        case .waiting(let continuation):
            state = .settled(result)
            timeoutTask?.cancel()
            continuation.resume(with: result)
        }
    }
}
