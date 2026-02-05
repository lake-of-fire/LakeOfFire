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
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
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
        try await ReaderFileManager.shared.delete(readerFileURL: url)
//        try await deleteRealmData()
        try await delete()
    }
    
    @MainActor
    public func cloudDriveSyncStatus() async throws -> CloudDriveSyncStatus {
        return try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: url)
    }
}
