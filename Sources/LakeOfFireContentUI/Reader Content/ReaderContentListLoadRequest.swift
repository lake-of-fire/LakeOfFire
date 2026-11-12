import Foundation
import LakeOfFireContent

/// A task identity, not a row identity: changing the filter must not recreate the
/// list's editing, selection or expansion state. Keep the original array equality
/// as well as value snapshots of ordering metadata on mutable Realm objects.
struct ReaderContentListLoadRequest<C: ReaderContentProtocol>: Equatable {
    let contents: [C]
    let contentFilterRevision: AnyHashable?
    let sortOrder: ReaderContentSortOrder
    let hasContentFilter: Bool
    let hasPostSortTransform: Bool
    private let itemRevisions: [ItemRevision?]

    private struct ItemRevision: Equatable {
        let compoundKey: String
        let url: URL
        let title: String
        let createdAt: Date
        let modifiedAt: Date
        let publicationDate: Date?
        let lastVisitedAt: Date?
        let isDeleted: Bool
    }

    @MainActor
    init(
        contents: [C],
        contentFilterRevision: AnyHashable? = nil,
        sortOrder: ReaderContentSortOrder,
        hasContentFilter: Bool,
        hasPostSortTransform: Bool = false
    ) {
        self.contents = contents
        self.contentFilterRevision = contentFilterRevision
        self.sortOrder = sortOrder
        self.hasContentFilter = hasContentFilter
        self.hasPostSortTransform = hasPostSortTransform
        itemRevisions = contents.map { content in
            guard !content.isInvalidated else { return nil }
            return ItemRevision(
                compoundKey: content.compoundKey,
                url: content.url,
                title: content.title,
                createdAt: content.createdAt,
                modifiedAt: content.modifiedAt,
                publicationDate: content.publicationDate,
                lastVisitedAt: (content as? HistoryRecord)?.lastVisitedAt,
                isDeleted: content.isDeleted
            )
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentFilterRevision == rhs.contentFilterRevision
            && lhs.sortOrder == rhs.sortOrder
            && lhs.hasContentFilter == rhs.hasContentFilter
            && lhs.hasPostSortTransform == rhs.hasPostSortTransform
            && lhs.itemRevisions == rhs.itemRevisions
            && lhs.contents == rhs.contents
    }
}

/// Called by the single view-owned task. The model intentionally suppresses
/// producer errors, so returning from load is not proof this caller is current.
@MainActor
func performReaderContentListLoad<C: ReaderContentProtocol>(
    viewModel: ReaderContentListViewModel<C>,
    request: ReaderContentListLoadRequest<C>,
    contentFilter: (@ReaderContentListActor (Int, C) async throws -> Bool)?,
    postSortTransform: (@ReaderContentListActor ([C]) -> [C])? = nil,
    isCurrent: @MainActor () -> Bool,
    onLoaded: @MainActor () async -> Void
) async {
    guard !Task.isCancelled, isCurrent() else { return }
    do {
        try await viewModel.load(
            contents: request.contents,
            contentFilter: contentFilter,
            sortOrder: request.sortOrder,
            postSortTransform: postSortTransform
        )
    } catch {
        return
    }
    guard !Task.isCancelled, isCurrent() else { return }
    await onLoaded()
}

/// Keep the layout delay on the owning task instead of leaving a queued scroll
/// callback behind when a filter changes or the list disappears.
@MainActor
func performReaderContentListScroll(
    isCurrent: @MainActor () -> Bool,
    waitForLayout: @MainActor () async throws -> Void = waitForReaderContentListLayout,
    scroll: @MainActor () -> Void
) async {
    guard !Task.isCancelled, isCurrent() else { return }
    do {
        try await waitForLayout()
    } catch {
        return
    }
    guard !Task.isCancelled, isCurrent() else { return }
    scroll()
}

@MainActor
private func waitForReaderContentListLayout() async throws {
    if #available(iOS 16, macOS 13, *) {
        try await Task.sleep(for: .milliseconds(100))
    } else {
        // The package still supports iOS 15, before Duration-based Task.sleep.
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
