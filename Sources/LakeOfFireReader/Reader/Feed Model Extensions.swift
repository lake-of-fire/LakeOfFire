import Foundation
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public extension Feed {
    @MainActor
    func fetch() async throws {
        try await fetch(realmConfiguration: ReaderContentLoader.feedEntryRealmConfiguration)
    }
}
