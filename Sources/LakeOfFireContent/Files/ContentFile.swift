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
        // Capture from the presented row before any actor hop. A late
        // ContentReference after physical removal can identify a replacement.
        guard let identity = DeletionIdentity(self) else { return }
        let manager = ReaderFileManager.shared
        let deletionContext = try manager.captureDeletionContext(source: identity)
        let transcriptContext = ReaderContentLoader.TranscriptDeletionContext(
            historyRealmConfiguration: identity.configuration,
            ownerHistoryRealmConfiguration: deletionContext.ownerConfiguration
        )
        try await manager.delete(readerFileURL: identity.url, context: deletionContext)
        // An already-tombstoned row may retry cleanup after an earlier failure.
        try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(
            contentURL: identity.url, context: transcriptContext
        )
    }

    /// Value identity only; managed objects are resolved on their owning actor.
    /// The public Realm row ID distinguishes same-key/same-date replacements.
    struct DeletionIdentity: @unchecked Sendable {
        let contentType: RealmSwift.Object.Type
        let key: String
        let objectID: UInt64
        let createdAt: Date
        let url: URL
        let wasDeleted: Bool
        let configuration: Realm.Configuration
        let storageAdmission: RealmStorageAdmission

        init?(_ content: ContentFile) {
            guard !content.isInvalidated, let realm = content.realm,
                  !realm.isInWriteTransaction else { return nil }
            contentType = type(of: content)
            key = content.compoundKey
            objectID = content.id
            createdAt = content.createdAt
            url = content.url
            wasDeleted = content.isDeleted
            configuration = realm.configuration
            storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(
                for: configuration
            )
        }

        func matches(_ content: ContentFile) -> Bool {
            guard !content.isInvalidated, let candidateRealm = content.realm,
                  Self.sameStore(configuration, candidateRealm.configuration) else { return false }
            return type(of: content) == contentType
                && content.compoundKey == key && content.id == objectID
                && content.createdAt == createdAt && content.url == url
        }

        private static func sameStore(_ first: Realm.Configuration, _ second: Realm.Configuration) -> Bool {
            if first.inMemoryIdentifier != nil || second.inMemoryIdentifier != nil {
                return first.inMemoryIdentifier == second.inMemoryIdentifier
            }
            guard let firstURL = first.fileURL, let secondURL = second.fileURL else { return false }
            return firstURL.standardizedFileURL == secondURL.standardizedFileURL
        }

        func validateStorage() throws {
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: configuration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
        }

        @RealmBackgroundActor
        func resolve(in realm: Realm) throws -> ContentFile? {
            try validateStorage()
            guard let content = realm.object(ofType: contentType, forPrimaryKey: key)
                    as? ContentFile, matches(content),
                  !wasDeleted || content.isDeleted else { return nil }
            return content
        }
    }
    
    @MainActor
    public func cloudDriveSyncStatus() async throws -> CloudDriveSyncStatus {
        return try await ReaderFileManager.shared.cloudDriveSyncStatus(readerFileURL: url)
    }
}
