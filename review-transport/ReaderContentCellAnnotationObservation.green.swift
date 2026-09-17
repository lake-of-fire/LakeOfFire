import Foundation

/// A view task owns this observation. Cancellation must be checked immediately
/// before publication; a suspended loader cannot publish into a departed row.
@MainActor
func observeReaderContentCellAnnotationStatus(
    updates: @MainActor () -> AsyncStream<ReaderContentCellAnnotationStatus>?,
    initialStatus: @MainActor () async -> ReaderContentCellAnnotationStatus,
    publish: @MainActor (ReaderContentCellAnnotationStatus) -> Void
) async {
    guard !Task.isCancelled else { return }
    if let stream = updates() {
        // These are complete per-row snapshots, not lossy invalidation IDs.
        // A host can coalesce them without adding any per-row Realm observer.
        for await value in stream {
            guard !Task.isCancelled else { return }
            publish(value)
        }
    } else {
        let value = await initialStatus()
        guard !Task.isCancelled else { return }
        publish(value)
    }
}
