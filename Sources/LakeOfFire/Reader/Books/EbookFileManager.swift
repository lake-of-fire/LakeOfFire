import Foundation
import LakeOfFire
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
                guard contentFile.url.pathExtension.lowercased() == "epub"
                        || contentFile.mimeType == "application/epub+zip"
                        || contentFile.mimeType == "directory"
                else {
                    continue
                }
                
                // Attempt to parse the EPUB for metadata + cover:
                do {
                    let localURL = try contentFile.systemFileURL
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

                        // If we found a cover href
                        // We'll build the URL scheme to read the cover image from the same 'reader-file' approach
                        // e.g. "reader-file://file/load/... ?subpath=<coverHref>"
                        let coverURLPrefix = contentFile.url.absoluteString.replacingOccurrences(of: "ebook://ebook/load/", with: "reader-file://file/load/") + "?subpath="
                        if let encodedPath = metadata.coverHref.addingPercentEncoding(withAllowedCharacters: subpathCharacterSet),
                           let coverImageURL = URL(string: coverURLPrefix + encodedPath), contentFile.imageUrl != coverImageURL {
                            toUpdateWithImage.append((contentFile, coverImageURL))
                        }
                        
                        if !contentFile.isPhysicalMedia {
                            toUpdateAsPhysicalMedia.append(contentFile)
                        }
                    }
                } catch {
                    Logger.shared.logger.error("EbookFileManager error: \(error)")
                }
            }
            
            if !toUpdateWithImage.isEmpty || !toUpdateWithTitle.isEmpty || !toUpdateWithAuthor.isEmpty || !toUpdateAsPhysicalMedia.isEmpty {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for (contentFile, imageURL) in toUpdateWithImage {
                        contentFile.imageUrl = imageURL
                    }
                    for (contentFile, title) in toUpdateWithTitle {
                        contentFile.title = title
                    }
                    for (contentFile, author) in toUpdateWithAuthor {
                        contentFile.author = author ?? ""
                    }
                    for (contentFile, publicationDate) in toUpdateWithPublicationDate {
                        contentFile.publicationDate = publicationDate
                    }
                    for contentFile in toUpdateAsPhysicalMedia {
                        contentFile.isPhysicalMedia = true
                    }
                }
            }
        })
    }
}
