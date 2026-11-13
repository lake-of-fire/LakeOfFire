import CryptoKit
import Foundation
import RealmSwift
import RealmSwiftGaps

public enum BookmarkInboxImportError: Error, Sendable {
    case missingInputs
    case emptyCanonicalPayload
    case incompatibleSchema
    case payloadDigestCollision
}

/// Capture once for a drain before suspension. The configuration stays immutable;
/// Gaps owns the reference-shared admission, including an exclusively created file.
public struct BookmarkInboxImportContext: @unchecked Sendable {
    fileprivate let realmConfiguration: Realm.Configuration
    fileprivate let storageAdmission: RealmStorageAdmission

    public init(realmConfiguration: Realm.Configuration) {
        self.realmConfiguration = realmConfiguration
        storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
    }

    public func validateCurrentStorage() throws {
        guard storageAdmission.matchesCurrentStorageIdentity({
            RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
        }) else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
    }

    /// The initial Reader warmup and its first drain must use this same context.
    @RealmBackgroundActor
    public func prepareStorage() async throws {
        _ = try await openRealm()
    }

    @RealmBackgroundActor
    fileprivate func openRealm() async throws -> Realm {
        try Task.checkCancellation()
        if let types = realmConfiguration.objectTypes {
            let containsBookmark = types.contains { ObjectIdentifier($0) == ObjectIdentifier(Bookmark.self) }
            let containsReceipt = types.contains {
                ObjectIdentifier($0) == ObjectIdentifier(ShareBookmarkApplicationReceipt.self)
            }
            guard containsBookmark && containsReceipt else {
                throw BookmarkInboxImportError.incompatibleSchema
            }
        }
        return try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
    }
}

// A throwing observation after the actual row and receipt changes, before commit.
// Tests use it to prove that the public operation rolls both back together.
enum BookmarkInboxImportObservation {
    @TaskLocal static var beforeCommit: (@RealmBackgroundActor @Sendable () throws -> Void)? = nil
}

public extension ReaderContentLoader {
    /// `canonicalPayload` is the caller's deterministic encoding of the same
    /// immutable request supplying these fields, including its UUID and date.
    /// Successful exact replays deliberately do not resolve or mutate the target.
    @RealmBackgroundActor
    static func saveInboxBookmark(
        inputURL: URL?,
        inputText: String?,
        inputTitle: String?,
        isReaderModeByDefault: Bool,
        canonicalPayload: Data,
        context: BookmarkInboxImportContext
    ) async throws {
        try Task.checkCancellation()
        guard !canonicalPayload.isEmpty else { throw BookmarkInboxImportError.emptyCanonicalPayload }
        guard inputURL != nil || inputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BookmarkInboxImportError.missingInputs
        }
        try context.validateCurrentStorage()
        let digest = SHA256.hash(data: canonicalPayload).map { String(format: "%02x", $0) }.joined()
        let realm = try await context.openRealm()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try context.validateCurrentStorage()
            if let receipt = realm.object(ofType: ShareBookmarkApplicationReceipt.self, forPrimaryKey: digest) {
                guard receipt.canonicalPayload == canonicalPayload else {
                    throw BookmarkInboxImportError.payloadDigestCollision
                }
                return
            }

            let timestamp = Date()
            let isFromClipboard = inputURL == nil
            let bookmark = Bookmark.addInOwnedWrite(
                url: inputURL,
                title: inputTitle ?? "",
                html: inputText.map { textToHTML($0) },
                isFromClipboard: isFromClipboard,
                rssContainsFullContent: isFromClipboard,
                isReaderModeByDefault: isReaderModeByDefault,
                isReaderModeAvailable: false,
                isReaderModeOfferHidden: false,
                realm: realm,
                at: timestamp
            )
            let receipt = ShareBookmarkApplicationReceipt()
            receipt.payloadDigest = digest
            receipt.canonicalPayload = canonicalPayload
            receipt.bookmarkID = bookmark.compoundKey
            receipt.appliedAt = timestamp
            realm.add(receipt)
            try BookmarkInboxImportObservation.beforeCommit?()
            try Task.checkCancellation()
            try context.validateCurrentStorage()
        }
    }
}
