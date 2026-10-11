import Foundation

/// The native receipt remains the owner across preparation and restore awaits.
/// Returning from an uncooperative callback never grants a replacement document
/// permission to consume the result.
@MainActor
enum ReaderEBookInitialization {
    static func prepareAndRestore<Binding: Equatable & Sendable, Prepared: Sendable, Restore: Sendable>(
        receiptBinding: Binding,
        currentBinding: () -> Binding?,
        prepare: (Binding) async throws -> Prepared,
        restore: (Binding) async throws -> Restore
    ) async throws -> (Prepared, Restore) {
        func validate() throws {
            try Task.checkCancellation()
            guard currentBinding() == receiptBinding else { throw CancellationError() }
        }
        try validate()
        let prepared = try await prepare(receiptBinding)
        try validate()
        let restored = try await restore(receiptBinding)
        try validate()
        return (prepared, restored)
    }
}
