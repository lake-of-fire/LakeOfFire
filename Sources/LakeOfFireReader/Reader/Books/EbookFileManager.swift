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

    public static func configure(readerFileManager: ReaderFileManager = .shared) {
        readerFileManager.registerFileProcessorBundle(
            identifier: "EbookFileManager",
            fileProcessorVersion: 1,
            readerContentMimeTypes: [.epub, .epubZip, .directory],
            destinationProcessor: { importedFileURL in
                if importedFileURL.isEBookURL {
                    return .ebooks
                }
                return nil
            },

            readerFileURLProcessor: { importedFileURL, encodedPathToCloudDriveFile in
                if importedFileURL.isEBookURL {
                    return URL(string: "ebook://ebook/load/" + encodedPathToCloudDriveFile)
                }
                return nil
            },

            contextualFileProcessor: { @RealmBackgroundActor context in
                let readerFileManager = context.readerFileManager
                let contentFiles = context.contentFiles
                var toUpdateWithImage = [(ContentFile, URL)]()
                var toUpdateWithTitle = [(ContentFile, String)]()
                var toUpdateWithAuthor = [(ContentFile, String?)]()
                var toUpdateWithPublicationDate = [(ContentFile, Date)]()
                var toUpdateAsPhysicalMedia = [ContentFile]()

                for contentFile in contentFiles {
                    // We'll determine it's an EPUB if the path extension is "epub" or if the mimeType suggests an EPUB/directory.
                    let pathExtension = contentFile.url.lakePathExtension.lowercased()
                    guard pathExtension == "epub"
                            || contentFile.mimeType == "application/epub+zip"
                            || contentFile.mimeType == "directory"
                    else {
                        continue
                    }

                    let localURL: URL
                    do {
                        localURL = try await readerFileManager.resolveReadableLocalURL(
                            forReaderBackingURL: contentFile.url
                        )
                    } catch {
                        context.deferPostprocessing(for: contentFile)
                        continue
                    }

                    // Attempt to parse the EPUB for metadata + cover:
                    let metadata: (
                        title: String,
                        author: String?,
                        coverHref: String?,
                        publicationDate: Date?
                    )
                    do {
                        guard let parsed = try EPubParser.parseMetadataAndCover(from: localURL) else {
                            context.deferPostprocessing(for: contentFile)
                            continue
                        }
                        metadata = parsed
                    } catch {
                        context.deferPostprocessing(for: contentFile)
                        continue
                    }
                    if contentFile.title != metadata.title {
                        toUpdateWithTitle.append((contentFile, metadata.title))
                    }
                    if contentFile.author != (metadata.author ?? "") {
                        toUpdateWithAuthor.append((contentFile, metadata.author))
                    }
                    if let publicationDate = metadata.publicationDate, contentFile.publicationDate != publicationDate {
                        toUpdateWithPublicationDate.append((contentFile, publicationDate))
                    }

                    if let coverHref = metadata.coverHref {
                        let coverURLPrefix = contentFile.url.absoluteString.replacingOccurrences(
                            of: "ebook://ebook/load/",
                            with: "reader-file://file/load/"
                        ) + "?subpath="
                        if let encodedPath = coverHref.addingPercentEncoding(
                            withAllowedCharacters: subpathCharacterSet
                        ),
                           let coverImageURL = URL(string: coverURLPrefix + encodedPath),
                           contentFile.imageUrl != coverImageURL {
                            toUpdateWithImage.append((contentFile, coverImageURL))
                        }
                    }

                    if !contentFile.isPhysicalMedia {
                        toUpdateAsPhysicalMedia.append(contentFile)
                    }
                }

                if !toUpdateWithImage.isEmpty || !toUpdateWithTitle.isEmpty
                    || !toUpdateWithAuthor.isEmpty
                    || !toUpdateWithPublicationDate.isEmpty
                    || !toUpdateAsPhysicalMedia.isEmpty {
                    let imageURL = toUpdateWithImage.first?.1
                    let title = toUpdateWithTitle.first?.1
                    let author = toUpdateWithAuthor.first?.1
                    let publicationDate = toUpdateWithPublicationDate.first?.1
                    let shouldMarkPhysicalMedia = !toUpdateAsPhysicalMedia.isEmpty
                    try await context.performCurrentWrite { _, contentFile in
                        let metadataDate = Date()
                        var changed = false
                        if let imageURL, contentFile.imageUrl != imageURL {
                            contentFile.imageUrl = imageURL
                            changed = true
                        }
                        if let title, contentFile.title != title {
                            contentFile.title = title
                            changed = true
                        }
                        if let author {
                            let resolvedAuthor = author ?? ""
                            if contentFile.author != resolvedAuthor {
                                contentFile.author = resolvedAuthor
                                changed = true
                            }
                        }
                        if let publicationDate,
                           contentFile.publicationDate != publicationDate {
                            contentFile.publicationDate = publicationDate
                            changed = true
                        }
                        if shouldMarkPhysicalMedia, !contentFile.isPhysicalMedia {
                            contentFile.isPhysicalMedia = true
                            changed = true
                        }
                        if changed {
                            contentFile.refreshChangeMetadata(
                                explicitlyModified: true,
                                at: metadataDate
                            )
                        }
                    }
                }
            }
        )
    }

    @RealmBackgroundActor
    static func applyMetadataUpdates(
        images: [(ContentFile, URL)],
        titles: [(ContentFile, String)],
        authors: [(ContentFile, String?)],
        publicationDates: [(ContentFile, Date)],
        physicalMedia: [ContentFile],
        at date: Date = Date()
    ) async throws {
        guard !images.isEmpty || !titles.isEmpty || !authors.isEmpty
            || !publicationDates.isEmpty || !physicalMedia.isEmpty else {
            return
        }
        guard let realm = images.first?.0.realm
            ?? titles.first?.0.realm
            ?? authors.first?.0.realm
            ?? publicationDates.first?.0.realm
            ?? physicalMedia.first?.realm else {
            return
        }

        try await realm.asyncWrite {
            var changedFiles = [String: ContentFile]()
            for (contentFile, imageURL) in images {
                if contentFile.imageUrl != imageURL {
                    contentFile.imageUrl = imageURL
                    changedFiles[contentFile.compoundKey] = contentFile
                }
            }
            for (contentFile, title) in titles {
                if contentFile.title != title {
                    contentFile.title = title
                    changedFiles[contentFile.compoundKey] = contentFile
                }
            }
            for (contentFile, author) in authors {
                let resolvedAuthor = author ?? ""
                if contentFile.author != resolvedAuthor {
                    contentFile.author = resolvedAuthor
                    changedFiles[contentFile.compoundKey] = contentFile
                }
            }
            for (contentFile, publicationDate) in publicationDates {
                if contentFile.publicationDate != publicationDate {
                    contentFile.publicationDate = publicationDate
                    changedFiles[contentFile.compoundKey] = contentFile
                }
            }
            for contentFile in physicalMedia where !contentFile.isPhysicalMedia {
                contentFile.isPhysicalMedia = true
                changedFiles[contentFile.compoundKey] = contentFile
            }
            for contentFile in changedFiles.values {
                contentFile.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: date
                )
            }
        }
    }
}
