import Foundation
import BigSyncKit
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

/// Values read from the admitted row, safe to present after its transaction settles.
public struct ReaderPageMetadataUpdateResult: Sendable {
    public let changed: Bool
    public let url: URL
    public let title: String
    public let isFromClipboard: Bool
    public let rssContainsFullContent: Bool
}

public extension ReaderContentLoader.ContentReference {
    /// Omitted author is a partial title update; an explicit empty author clears it.
    /// Resolve and compare inside the existing owned transaction so concurrent
    /// author edits are preserved and unchanged messages do not re-journal.
    @RealmBackgroundActor
    func writePageMetadata(
        title: String,
        author: String?,
        isAdmitted: @escaping @Sendable () -> Bool
    ) async throws -> ReaderPageMetadataUpdateResult? {
        try Task.checkCancellation()
        guard isAdmitted() else { return nil }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard isAdmitted() else { return nil }
            try validateStorage()
            guard let content = resolveForMutation(in: realm), !content.isDeleted else { return nil }
            let finalTitle = title.removingClipboardIndicatorIfNeeded(
                content.isFromClipboard || content.url.isSnippetURL
            )
            guard !finalTitle.isEmpty else { return nil }
            let existingTitle = content.title
                .replacingOccurrences(of: String("\u{fffc}"), with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let titleChanged = existingTitle != finalTitle
            let authorChanged = author.map { content.author != $0 } ?? false
            if titleChanged || authorChanged {
                if titleChanged { content.title = finalTitle }
                if let author, authorChanged { content.author = author }
                content.refreshChangeMetadata(explicitlyModified: true, at: Date())
            }
            // Metadata hooks can revoke/cancel this attempt or replace its file.
            try Task.checkCancellation()
            guard isAdmitted() else { throw CancellationError() }
            try validateStorage()
            return ReaderPageMetadataUpdateResult(
                changed: titleChanged || authorChanged,
                url: content.url, title: content.title,
                isFromClipboard: content.isFromClipboard,
                rssContainsFullContent: content.rssContainsFullContent
            )
        }
    }
}
