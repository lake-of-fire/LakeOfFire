import Foundation
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation
import LakeOfFireCore
import LakeOfFireAdblock

public class ContentFile: Bookmark {
    @Persisted public var mimeType = "application/octet-stream"
    @Persisted public var packageFilePaths = RealmSwift.MutableSet<String>()
    @Persisted public var fileMetadataRefreshedAt: Date?
    
    public var systemFileURL: URL {
        get throws {
            try ReaderFileManager.shared.localFileURL(forReaderFileURL: url)
        }
    }
    
    public override func configureBookmark(_ bookmark: Bookmark, at timestamp: Date) {
        super.configureBookmark(bookmark, at: timestamp)
    }
    
    public override var deleteActionTitle: String {
        "Delete File…"
    }
    
    public override var deletionConfirmationTitle: String {
        return "Deletion Confirmation"
    }
    
    public override var deletionConfirmationMessage: String {
        return "Are you sure you want to delete from storage?"
    }
    
    public override var deletionConfirmationActionTitle: String {
        return "Delete"
    }
    
    public func zipArchive(accessMode: Archive.AccessMode = .read) throws -> Archive? {
        try Archive(url: systemFileURL, accessMode: accessMode)
    }
    
    @MainActor
    public override func delete() async throws {
        try await delete(readerFileManager: .shared)
    }

    @MainActor
    public func delete(readerFileManager: ReaderFileManager) async throws {
        let contentURL = url
        try await readerFileManager.delete(readerFileURL: contentURL)
        try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(
            contentURL: contentURL
        )
    }
    
    @MainActor
    public func cloudDriveSyncStatus() async throws -> CloudDriveSyncStatus {
        return try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: url)
    }
}
