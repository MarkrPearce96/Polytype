import Foundation
#if canImport(Translation)
import Translation
import SwiftUI
import AppKit

/// On-device translation via Apple's Translation framework (used for zh-TW).
///
/// Apple's `Translation` framework has no supported standalone async API: a
/// `TranslationSession` is only ever vended to a SwiftUI view via the
/// `.translationTask(_:action:)` modifier. Since our input method has no natural
/// SwiftUI view for translation, this hosts an offscreen SwiftUI view internally
/// (see `SessionProvider` below) purely to obtain a session, then bridges it to
/// plain async/await so `FallbackChain` can use it like any other `TranslationEngine`.
///
/// NOTE: This is the project's one genuinely tricky integration. It is architected
/// and compiles cleanly, but the offscreen-session bridge can only be exercised with
/// a real app run loop/window server, so runtime behavior is verified manually inside
/// the running app (Task 8/9), not here.
@available(macOS 15.0, *)
public final class AppleEngine: TranslationEngine, @unchecked Sendable {
    public init() {}

    public func translate(_ english: String, to target: String) async throws -> String {
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: target)  // e.g. "zh-TW"
        )
        do {
            let session = try await SessionProvider.session(for: config)
            let response = try await session.translate(english)
            guard !response.targetText.isEmpty else { throw TranslationError.empty }
            return response.targetText
        } catch let e as TranslationError {
            throw e
        } catch {
            throw TranslationError.network("apple: \(error)")
        }
    }
}

/// Bridges Apple's SwiftUI-only `TranslationSession` API to async/await.
///
/// `TranslationSession` has no supported standalone initializer on macOS 15-25 (macOS 26
/// adds `init(installedSource:target:)`, but only for already-installed language pairs,
/// and this package's floor is macOS 14 / gate is macOS 15, so it can't be relied on as
/// the primary path here). The system only vends a session to a SwiftUI view via
/// `.translationTask(_:action:)`. To use it from a plain async context, this hosts a
/// throwaway `NSHostingView` carrying that modifier inside a practically-invisible
/// `NSWindow`, captures the session the system hands to the view, and resumes a
/// `CheckedContinuation` with it.
///
/// The host window is kept ON the main screen (not moved off the physical display) at
/// near-zero alpha and 1x1 size: if the system needs a real anchor point to present its
/// language-pack download consent sheet the first time a pack is missing, an offscreen
/// (off-display) window would make that sheet impossible for the user to see or approve.
/// `orderFrontRegardless()` (never `makeKeyAndOrderFront`) keeps this from stealing key
/// window / keyboard focus from whatever the user is actually typing into.
@available(macOS 15.0, *)
@MainActor
final class SessionProvider {
    /// Cached for the process lifetime: recreating the host window on every call would
    /// re-run (and potentially re-prompt for) the language download flow each time.
    private static var current: SessionProvider?

    /// How long to wait for the system to vend a session before giving up, so a stalled
    /// bridge (e.g. the offscreen host never getting a rendering pass) surfaces as a
    /// thrown `TranslationError` instead of hanging `AppleEngine.translate` forever.
    private static let sessionTimeout: Duration = .seconds(20)

    private var window: NSWindow?
    private var continuation: CheckedContinuation<TranslationSession, Never>?
    private var cachedSession: TranslationSession?
    private var cachedConfiguration: TranslationSession.Configuration?

    static func session(for configuration: TranslationSession.Configuration) async throws -> TranslationSession {
        try await withThrowingTaskGroup(of: TranslationSession.self) { group in
            group.addTask { @MainActor in
                let provider = current ?? SessionProvider()
                current = provider
                return await provider.resolveSession(for: configuration)
            }
            group.addTask {
                try await Task.sleep(for: sessionTimeout)
                throw TranslationError.network("apple: timed out waiting for TranslationSession")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TranslationError.network("apple: session resolution produced no result")
            }
            return first
        }
    }

    private func resolveSession(for configuration: TranslationSession.Configuration) async -> TranslationSession {
        if let cachedSession, cachedConfiguration == configuration {
            return cachedSession
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<TranslationSession, Never>) in
            self.continuation = continuation
            self.cachedConfiguration = configuration
            installHostingWindow(configuration: configuration)
        }
    }

    private func installHostingWindow(configuration: TranslationSession.Configuration) {
        window?.close()

        let hostingView = NSHostingView(
            rootView: TranslationBridgeView(configuration: configuration) { [weak self] session in
                self?.handle(session)
            }
        )

        // Anchored within the main screen's bounds (not off the physical display) so
        // that, if the system needs to present a language-pack download sheet, it has a
        // real point to anchor to. Near-zero alpha plus 1x1 size keep it invisible to
        // the user regardless of on-screen position.
        let origin = NSScreen.main?.frame.origin ?? .zero
        let window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = hostingView
        window.orderFrontRegardless()

        self.window = window
    }

    private func handle(_ session: TranslationSession) {
        guard let continuation else { return }
        self.continuation = nil
        cachedSession = session
        continuation.resume(returning: session)
    }
}

/// A trivial SwiftUI view whose only purpose is to carry `.translationTask` so the
/// system will vend us a `TranslationSession`.
@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    let configuration: TranslationSession.Configuration
    let onSession: (TranslationSession) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                onSession(session)
                // The session is only valid while this closure is running; SwiftUI
                // tears it down once we return. Stay suspended (waking periodically
                // only to check for cancellation) so the session remains usable for as
                // long as the app keeps this bridge installed.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
    }
}
#else
/// Translation framework unavailable on this platform/SDK: fail closed so
/// `FallbackChain` still has a well-typed engine to call.
public final class AppleEngine: TranslationEngine, @unchecked Sendable {
    public init() {}
    public func translate(_ english: String, to target: String) async throws -> String {
        throw TranslationError.network("Translation framework unavailable")
    }
}
#endif
