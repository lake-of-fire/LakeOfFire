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

                guard let localURL = try? await ReaderFileManager.shared.resolveReadableLocalURL(forReaderBackingURL: contentFile.url) else {
                    continue
                }

                // Attempt to parse the EPUB for metadata + cover:
                do {
                    if let metadata = try EPubParser.parseMetadataAndCover(from: localURL) {
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
                } catch {
                    continue
                }
            }

            if !toUpdateWithImage.isEmpty || !toUpdateWithTitle.isEmpty
                || !toUpdateWithAuthor.isEmpty
                || !toUpdateWithPublicationDate.isEmpty
                || !toUpdateAsPhysicalMedia.isEmpty {
                try await applyMetadataUpdates(
                    images: toUpdateWithImage,
                    titles: toUpdateWithTitle,
                    authors: toUpdateWithAuthor,
                    publicationDates: toUpdateWithPublicationDate,
                    physicalMedia: toUpdateAsPhysicalMedia
                )
            }
        })
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
