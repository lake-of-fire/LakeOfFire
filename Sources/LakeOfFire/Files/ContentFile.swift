import Foundation
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation

public class ContentFile: Bookmark, PhysicalMediaCapableProtocol {
    @Persisted public var mimeType = "application/octet-stream"
    @Persisted public var packageFilePaths = RealmSwift.MutableSet<String>()
    @Persisted public var fileMetadataRefreshedAt: Date?
    @Persisted public var isPhysicalMedia = false

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
    public func delete(readerFileManager: ReaderFileManager) async throws {
        try await readerFileManager.delete(readerFileURL: url)
        try await deleteRealmData()
    }
    
    @MainActor
    func cloudDriveSyncStatus(readerFileManager: ReaderFileManager) async throws -> CloudDriveSyncStatus {
        return try await readerFileManager.cloudDriveSyncStatus(readerFileURL: url)
    }
}
