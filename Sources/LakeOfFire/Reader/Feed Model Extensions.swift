import Foundation

public extension Feed {
    @MainActor
    func fetch() async throws {
        try await fetch(realmConfiguration: ReaderContentLoader.feedEntryRealmConfiguration)
    }
}
