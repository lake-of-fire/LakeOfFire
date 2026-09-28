import Foundation

/// One initialization receipt owns the entire register/acknowledge/prepare/
/// restore/load sequence. The token is native input, not a URL or JS payload.
/// A same-URL document replacement must not be recaptured after suspension.
///
/// This function coordinates the real handler callbacks. Callback operations
/// still validate the supplied binding at their own final side-effect boundary
/// (notably WebViewScriptCaller.evaluateJavaScript(requiring:)). A later error
/// cannot roll back an acknowledgment or neutral Article already committed.
@MainActor
enum ReaderEBookInitialization {
    static func perform<Binding: Equatable & Sendable, Prepared: Sendable, Restore: Sendable>(
        receiptBinding: Binding?,
        currentBinding: () -> Binding?,
        registerFrame: (Binding) throws -> Void,
        acknowledge: (Binding) async throws -> Void,
        prepare: (Binding) async throws -> Prepared,
        restore: (Binding) async throws -> Restore,
        publish: (Binding, Prepared, Restore) async throws -> Void
    ) async throws {
        guard let binding = receiptBinding else { throw CancellationError() }
        func validate() throws {
            try Task.checkCancellation()
            guard currentBinding() == binding else { throw CancellationError() }
        }
        try validate()
        try registerFrame(binding)
        try validate()
        try await acknowledge(binding)
        try validate()
        let prepared = try await prepare(binding)
        try validate()
        let position = try await restore(binding)
        try validate()
        try await publish(binding, prepared, position)
    }
}
