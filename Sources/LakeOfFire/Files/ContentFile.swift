import Foundation
import RealmSwift
import RealmSwiftGaps

public class ContentFile: Bookmark {
    @Persisted public var mimeType = "application/octet-stream"
    @Persisted public var packageFilePaths = RealmSwift.MutableSet<String>()
    @Persisted public var fileMetadataRefreshedAt: Date?
    @Persisted public var isPhysicalMedia = false

    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}

extension ContentFile: DeletableReaderContent {
    public var deleteActionTitle: String {
        "Delete File…"
    }
    
    @MainActor
    public func delete(readerFileManager: ReaderFileManager) async throws {
        try await readerFileManager.delete(readerFileURL: url)
        try await deleteRealmData()
    }
    
    @MainActor
    func cloudDriveSyncStatus(readerFileManager: ReaderFileManager) async throws -> CloudDriveSyncStatus {
        return try await readerFileManager.cloudDriveSyncStatus(readerFileURL: url)
    }
}
