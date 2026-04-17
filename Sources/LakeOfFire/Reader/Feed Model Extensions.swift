import Foundation

public extension Feed {
    @MainActor
    func fetch() async throws {
        try await fetch(realmConfiguration: ReaderContentLoader.feedEntryRealmConfiguration)
    }

    var firstEntryHasAudio: Bool {
        getEntries()?.first?.hasAudio ?? false
    }

    var latestEntryCreatedAt: Date? {
        getEntries()?.map(\.createdAt).max()
    }

    var hasEntriesNewerThanLastViewedAt: Bool {
        guard let lastViewedAt else { return false }
        return getEntries()?.contains(where: { $0.createdAt > lastViewedAt }) ?? false
    }

    var shouldRefreshOnCategoryAppear: Bool {
        let entries = getEntries() ?? []
        guard !entries.isEmpty else { return true }
        guard let lastViewedAt,
              let latestEntryCreatedAt else {
            return false
        }
        return latestEntryCreatedAt < lastViewedAt
    }
}
