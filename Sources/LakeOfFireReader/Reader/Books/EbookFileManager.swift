import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation
import UniformTypeIdentifiers
import SwiftCloudDrive
import Logging
import LakeKit

public extension RootRelativePath {
    static let ebooks = Self(path: "Books")
}

public struct EbookFileManager {
    public static func configure() {
        for mimeType in [UTType.epub, .epubZip, .directory] {
            if !ReaderFileManager.shared.readerContentMimeTypes.contains(mimeType) {
                ReaderFileManager.shared.readerContentMimeTypes.append(mimeType)
            }
        }
        ReaderFileManager.fileDestinationProcessors.append({ importedFileURL in
            importedFileURL.isEBookURL ? .ebooks : nil
        })
        ReaderFileManager.readerFileURLProcessors.append({ importedFileURL, encodedPath in
            importedFileURL.isEBookURL ? URL(string: "ebook://ebook/load/" + encodedPath) : nil
        })
        ReaderFileManager.fileEnrichmentProcessors["epub"] = { contentFiles in
            try await enrichMetadata(contentFiles)
        }
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

    /// Confined to RealmBackgroundActor throughout preparation and commit.
    /// Retaining the original object rejects hard deletion/recreation too: a
    /// same-primary-key replacement must not inherit this object's proposal.
    @RealmBackgroundActor
    struct MetadataUpdate {
        let file: ContentFile
        let realm: Realm
        let id: String
        let url: URL
        let modifiedAt: Date
        let original: MetadataValues
        var desired: MetadataValues

        init?(_ file: ContentFile) {
            guard !file.isInvalidated, !file.isFrozen, !file.isDeleted,
                  let realm = file.realm else { return nil }
            self.file = file
            self.realm = realm
            id = file.compoundKey
            url = file.url
            modifiedAt = file.modifiedAt
            original = MetadataValues(file)
            desired = original
        }

        var isCurrent: Bool {
            !file.isInvalidated && !file.isFrozen && !file.isDeleted
                && file.realm == realm && file.compoundKey == id
                && file.url == url && file.modifiedAt == modifiedAt
                && MetadataValues(file) == original
        }
    }

    @RealmBackgroundActor
    static func enrichMetadata(
        _ contentFiles: [ContentFile],
        status: @MainActor (URL) async throws -> CloudDriveSyncStatus = {
            try await ReaderFileManager.shared.cloudDriveSyncStatus(forReaderBackingURL: $0)
        }
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        var deferredIDs = Set<String>()
        var updates = [MetadataUpdate]()
        for contentFile in contentFiles {
            try Task.checkCancellation()
            guard var update = MetadataUpdate(contentFile) else { continue }
            let pathExtension = update.url.lakePathExtension.lowercased()
            guard pathExtension == "epub"
                    || contentFile.mimeType == "application/epub+zip"
                    || contentFile.mimeType == "directory" else { continue }
            guard let readerBackingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: update.url) else {
                deferredIDs.insert(update.id)
                continue
            }
            do {
                let syncStatus = try await status(readerBackingURL)
                try Task.checkCancellation()
                guard update.isCurrent,
                      syncStatus == .availableLocally || syncStatus == .localOnly || syncStatus == .uploading else {
                    deferredIDs.insert(update.id)
                    continue
                }
                let localURL = try contentFile.systemFileURL
                guard let metadata = try EPubParser.parseMetadataAndCover(from: localURL) else {
                    deferredIDs.insert(update.id)
                    continue
                }
                update.desired.title = metadata.title
                update.desired.author = metadata.author ?? ""
                if let publicationDate = metadata.publicationDate {
                    update.desired.publicationDate = publicationDate
                }
                // Missing artwork is not failed metadata. Preserve an existing
                // image rather than clearing it without provenance.
                if let cover = metadata.coverHref,
                   var components = URLComponents(url: readerBackingURL, resolvingAgainstBaseURL: false) {
                    components.queryItems = [URLQueryItem(name: "subpath", value: cover)]
                    components.fragment = nil
                    if let imageURL = components.url { update.desired.imageURL = imageURL }
                }
                update.desired.isPhysicalMedia = true
                updates.append(update)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                deferredIDs.insert(update.id)
            }
        }
        // An await for a later file can invalidate an earlier proposal. Admit
        // the whole per-file snapshot at the real Realm transaction boundary.
        deferredIDs.formUnion(try await applyPreparedMetadataUpdates(updates))
        return deferredIDs
    }

    @RealmBackgroundActor
    @discardableResult
    static func applyPreparedMetadataUpdates(
        _ updates: [MetadataUpdate], at date: Date = Date()
    ) async throws -> Set<String> {
        try Task.checkCancellation()
        var groups: [(realm: Realm, updates: [MetadataUpdate])] = []
        for update in updates {
            if let index = groups.firstIndex(where: { $0.realm == update.realm }) {
                groups[index].updates.append(update)
            } else {
                groups.append((update.realm, [update]))
            }
        }
        var deferredIDs = Set<String>()
        for group in groups {
            try Task.checkCancellation()
            try await group.realm.asyncWrite {
                // asyncWrite may acquire its transaction after cancellation or
                // an intervening Realm notification. Check inside the closure.
                try Task.checkCancellation()
                for update in group.updates {
                    guard update.isCurrent else {
                        deferredIDs.insert(update.id)
                        continue
                    }
                    guard update.original != update.desired else { continue }
                    let file = update.file
                    file.title = update.desired.title
                    file.author = update.desired.author
                    file.imageUrl = update.desired.imageURL
                    file.publicationDate = update.desired.publicationDate
                    file.isPhysicalMedia = update.desired.isPhysicalMedia
                    file.refreshChangeMetadata(explicitlyModified: true, at: date)
                }
                // A cancellation arriving during a large batch must roll back
                // its metadata and journal writes together.
                try Task.checkCancellation()
            }
        }
        return deferredIDs
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
        at date: Date = Date()
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
