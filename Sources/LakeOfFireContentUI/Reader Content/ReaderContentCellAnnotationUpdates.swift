import Foundation
import SwiftUI

private struct ReaderContentCellAnnotationStatusUpdatesKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL, String) -> AsyncStream<ReaderContentCellAnnotationStatus>)? = nil
}

public extension EnvironmentValues {
    var readerContentCellAnnotationStatusUpdates: (@MainActor (URL, String) -> AsyncStream<ReaderContentCellAnnotationStatus>)? {
        get { self[ReaderContentCellAnnotationStatusUpdatesKey.self] }
        set { self[ReaderContentCellAnnotationStatusUpdatesKey.self] = newValue }
    }
}

public extension View {
    /// Provide complete, initially replayed per-row snapshots. The cell's view
    /// task cancels its subscription on disappearance or identity replacement.
    /// Hosts without a stream retain the existing one-shot loader behavior.
    func readerContentCellAnnotationStatusUpdates(
        _ updates: @escaping @MainActor (URL, String) -> AsyncStream<ReaderContentCellAnnotationStatus>
    ) -> some View {
        environment(\.readerContentCellAnnotationStatusUpdates, updates)
    }
}
