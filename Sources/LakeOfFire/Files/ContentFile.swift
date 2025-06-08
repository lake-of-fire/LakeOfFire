import Foundation
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation

public class ContentFile: Bookmark {
    @Persisted public var mimeType = "application/octet-stream"
    @Persisted public var packageFilePaths = RealmSwift.MutableSet<String>()
    @Persisted public var fileMetadataRefreshedAt: Date?
    
    public var systemFileURL: URL {
        get throws {
            try ReaderFileManager.shared.localFileURL(forReaderFileURL: url)
        }
    }
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
    
    public func zipArchive(accessMode: Archive.AccessMode = .read) throws -> Archive? {
        try Archive(url: systemFileURL, accessMode: accessMode)
    }
}

extension ContentFile: DeletableReaderContent {
    public var deleteActionTitle: String {
        "Delete File…"
    }
    
    @MainActor
    public func delete() async throws {
        try await ReaderFileManager.shared.delete(readerFileURL: url)
//        try await deleteRealmData()
        try await delete()
    }
    
    @MainActor
    func cloudDriveSyncStatus() async throws -> CloudDriveSyncStatus {
        return try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: url)
    }
}
