import Foundation
import LakeOfFireCore

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
        try await ReaderLoadTrace.$operationID.withValue(ReaderLoadTrace.operationID ?? UUID()) {
            let trace = ReaderLoadTrace.begin("ebook.initialization")
            var step = "validation"
            var outcome = "failed"
            var failureDetail = ""
            defer { trace?.end("step=\(step) outcome=\(outcome)\(failureDetail)") }
            func beginStep(_ name: String) {
                step = name
                ReaderLoadTrace.event("ebook.initializationStep", "step=\(name)")
            }
            do {
                try validate()
                beginStep("register")
                try registerFrame(binding)
                try validate()
                beginStep("acknowledge")
                try await acknowledge(binding)
                try validate()
                beginStep("prepare")
                let prepared = try await prepare(binding)
                try validate()
                beginStep("restore")
                let position = try await restore(binding)
                try validate()
                beginStep("publish")
                try await publish(binding, prepared, position)
                outcome = "ready"
            } catch {
                outcome = error is CancellationError ? "cancelled" : "failed"
                // Type and numeric code identify the failure without recording
                // descriptions which can contain paths, URLs or article data.
                failureDetail = " error_type=\(String(reflecting: type(of: error)).prefix(160)) error_code=\((error as NSError).code)"
                throw error
            }
        }
    }
}
