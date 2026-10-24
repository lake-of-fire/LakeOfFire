import Foundation
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation
import UniformTypeIdentifiers
import SwiftCloudDrive
import Logging
import LakeKit
import LakeOfFireContent
import LakeOfFireCore

public extension RootRelativePath {
    static let ebooks = Self(path: "Books")
}

public struct EbookFileManager {
    private static let subpathCharacterSet = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&="))

    public static func configure() {
        for mimeType in [UTType.epub, .epubZip, .directory] {
            if !ReaderFileManager.shared.readerContentMimeTypes.contains(mimeType) {
                ReaderFileManager.shared.readerContentMimeTypes.append(mimeType)
            }
        }

        ReaderFileManager.fileDestinationProcessors.append({ importedFileURL in
            if importedFileURL.isEBookURL {
                return .ebooks
            }
            return nil
        })

        ReaderFileManager.readerFileURLProcessors.append({ importedFileURL, encodedPathToCloudDriveFile in
            if importedFileURL.isEBookURL {
                return URL(string: "ebook://ebook/load/" + encodedPathToCloudDriveFile)
            }
            return nil
        })

        ReaderFileManager.fileProcessors.append({ @RealmBackgroundActor contentFiles in
            _ = try await enrichMetadata(contentFiles)
        })
    }

    /// A value snapshot, not live Realm fields consulted after an await.
    struct MetadataValues: Equatable {
        var title: String
        var author: String
        var imageURL: URL?
        var publicationDate: Date?
        var isPhysicalMedia: Bool

        init(_ file: ContentFile) {
            title = file.title
            author = file.author
            imageURL = file.imageUrl
            publicationDate = file.publicationDate
            isPhysicalMedia = file.isPhysicalMedia
        }
    }

    /// Actor-confined proposal for the original row, captured before file I/O.
    /// The retained accessor rejects deletion/recreation even if a successor
    /// reuses the key and creation date. It is never used after invalidation.
    @RealmBackgroundActor
    struct MetadataUpdate {
        let file: ContentFile
        let realm: Realm
        let configuration: Realm.Configuration
        let storageAdmission: RealmStorageAdmission
        let id: String
        let createdAt: Date
        let url: URL
        let mimeType: String
        let modifiedAt: Date
        let original: MetadataValues
        var desired: MetadataValues

        init?(_ file: ContentFile) {
            guard !file.isInvalidated, !file.isFrozen, !file.isDeleted,
                  let realm = file.realm else { return nil }
            self.file = file
            self.realm = realm
            configuration = realm.configuration
            storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
            id = file.compoundKey
            createdAt = file.createdAt
            url = file.url
            mimeType = file.mimeType
            modifiedAt = file.modifiedAt
            original = MetadataValues(file)
            desired = original
        }

        func validateStorage() throws {
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: configuration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        }

        func currentFile() -> ContentFile? {
            guard !file.isInvalidated, !file.isFrozen,
                  let current = realm.object(ofType: ContentFile.self, forPrimaryKey: id),
                  !current.isDeleted, current.createdAt == createdAt,
                  current.url == url, current.mimeType == mimeType,
                  current.modifiedAt == modifiedAt,
                  MetadataValues(current) == original else { return nil }
            return current
        }
    }

    /// Keep selected upstream's resolver and processor API. Rejected IDs expose
    /// the local outcome to callers/tests; they do not install a retry policy.
    @RealmBackgroundActor
    @discardableResult
    static func enrichMetadata(
        _ contentFiles: [ContentFile],
        resolveLocalURL: (@MainActor (URL) async throws -> URL)? = nil
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        let manager = ReaderFileManager.shared
        let resolve: @MainActor (URL) async throws -> URL = resolveLocalURL ?? { url in
            try await manager.resolveReadableLocalURL(forReaderBackingURL: url)
        }
        var rejectedIDs = Set<String>()
        var updates = [MetadataUpdate]()
        for contentFile in contentFiles {
            try Task.checkCancellation()
            guard var update = MetadataUpdate(contentFile) else { continue }
            let pathExtension = update.url.lakePathExtension.lowercased()
            guard pathExtension == "epub"
                    || update.mimeType == "application/epub+zip"
                    || update.mimeType == "directory" else { continue }
            let localURL: URL
            do {
                localURL = try await resolve(update.url)
            } catch {
                // A failed availability check is still best effort; task
                // cancellation must never become a successful partial batch.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                rejectedIDs.insert(update.id)
                continue
            }
            try Task.checkCancellation()
            try update.validateStorage()
            guard update.currentFile() != nil else {
                rejectedIDs.insert(update.id)
                continue
            }
            do {
                guard let metadata = try EPubParser.parseMetadataAndCover(from: localURL) else {
                    rejectedIDs.insert(update.id)
                    continue
                }
                update.desired.title = metadata.title
                update.desired.author = metadata.author ?? ""
                if let publicationDate = metadata.publicationDate {
                    update.desired.publicationDate = publicationDate
                }
                // Preserve the selected cover transport and missing-field
                // policy; parser/URL behavior has separate compositions.
                if let coverHref = metadata.coverHref {
                    let prefix = update.url.absoluteString.replacingOccurrences(
                        of: "ebook://ebook/load/", with: "reader-file://file/load/"
                    ) + "?subpath="
                    if let path = coverHref.addingPercentEncoding(withAllowedCharacters: subpathCharacterSet),
                       let imageURL = URL(string: prefix + path) {
                        update.desired.imageURL = imageURL
                    }
                }
                update.desired.isPhysicalMedia = true
                updates.append(update)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                rejectedIDs.insert(update.id)
            }
        }
        rejectedIDs.formUnion(try await applyPreparedMetadataUpdates(updates))
        return rejectedIDs
    }

    @RealmBackgroundActor
    @discardableResult
    static func applyPreparedMetadataUpdates(
        _ updates: [MetadataUpdate], at date: Date? = nil
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        var groups: [(realm: Realm, updates: [MetadataUpdate])] = []
        for update in updates {
            try update.validateStorage()
            if let index = groups.firstIndex(where: { $0.realm == update.realm }) {
                groups[index].updates.append(update)
            } else {
                groups.append((update.realm, [update]))
            }
        }
        var rejectedIDs = Set<String>()
        for group in groups {
            try Task.checkCancellation()
            try await group.realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                let mutationDate = date ?? Date()
                for update in group.updates {
                    try update.validateStorage()
                    guard let file = update.currentFile() else {
                        rejectedIDs.insert(update.id)
                        continue
                    }
                    guard update.original != update.desired else { continue }
                    file.title = update.desired.title
                    file.author = update.desired.author
                    file.imageUrl = update.desired.imageURL
                    file.publicationDate = update.desired.publicationDate
                    file.isPhysicalMedia = update.desired.isPhysicalMedia
                    file.refreshChangeMetadata(explicitlyModified: true, at: mutationDate)
                }
                try Task.checkCancellation()
                for update in group.updates { try update.validateStorage() }
            }
        }
        return rejectedIDs
    }

    /// Retain the internal batch API used by existing callers/tests, but route
    /// it through the same per-object ownership and per-Realm transaction path.
    @RealmBackgroundActor
    static func applyMetadataUpdates(
        images: [(ContentFile, URL)],
        titles: [(ContentFile, String)],
        authors: [(ContentFile, String?)],
        publicationDates: [(ContentFile, Date)],
        physicalMedia: [ContentFile],
        at date: Date? = nil
    ) async throws {
        try Task.checkCancellation()
        var updates = [MetadataUpdate]()
        var realms = [Realm]()
        var indices = [Int: [String: Int]]()
        @RealmBackgroundActor
        func set(_ file: ContentFile, _ mutation: (inout MetadataValues) -> Void) {
            guard !file.isInvalidated, let realm = file.realm else { return }
            let realmIndex: Int
            if let existing = realms.firstIndex(of: realm) {
                realmIndex = existing
            } else {
                realmIndex = realms.count
                realms.append(realm)
            }
            // Two managed wrappers can denote the same row. Scope by Realm
            // and primary key, not the Swift wrapper's ObjectIdentifier.
            let key = file.compoundKey
            let index: Int
            if let existing = indices[realmIndex]?[key] {
                index = existing
            } else {
                guard let update = MetadataUpdate(file) else { return }
                index = updates.count
                indices[realmIndex, default: [:]][key] = index
                updates.append(update)
            }
            mutation(&updates[index].desired)
        }
        for (file, value) in images { set(file) { $0.imageURL = value } }
        for (file, value) in titles { set(file) { $0.title = value } }
        for (file, value) in authors { set(file) { $0.author = value ?? "" } }
        for (file, value) in publicationDates { set(file) { $0.publicationDate = value } }
        for file in physicalMedia { set(file) { $0.isPhysicalMedia = true } }
        _ = try await applyPreparedMetadataUpdates(updates, at: date)
    }
}
