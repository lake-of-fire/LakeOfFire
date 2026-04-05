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
        guard let contentRef = ReaderContentLoader.ContentReference(content: self) else { return }
        try await { @RealmBackgroundActor in
            guard let content = try await contentRef.resolveOnBackgroundActor() else { return }
            try await content.realm?.asyncWrite {
                content.isDeleted = true
                content.refreshChangeMetadata(explicitlyModified: true)
            }
        }()
    }
    
    @MainActor
    func cloudDriveSyncStatus() async throws -> CloudDriveSyncStatus {
        return try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: url)
    }
}
