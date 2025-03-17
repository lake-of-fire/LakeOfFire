import Foundation
import LakeOfFire
import RealmSwift
import RealmSwiftGaps
import ZIPFoundation
import UniformTypeIdentifiers
import SwiftCloudDrive

public extension RootRelativePath {
    static let ebooks = Self(path: "Books")
}

fileprivate let mokuroImageExtensions = ["jpg", "jpeg", "png", "webp"]

public struct EbookFileManager {
    private static let subpathCharacterSet = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&="))
    
    public static func configure() {
        for mimeType: [UTType] in [.epub, .epubZip, .directory] {
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
            var toUpdateAsPhysicalMedia = [ContentFile]()
            
            let readerRealm = try await RealmBackgroundActor.shared.readerRealm
            
            for contentFile in contentFiles where contentFile.url.pathExtension == "zip" && contentFile.packageFilePaths.contains("_ocr/") {
                if readerRealm.objects(ContentPackageFile.self).where({ $0.packageContentFileID == contentFile.compoundKey && !$0.isDeleted }).isEmpty, let mokuroVolumes = contentFile.mokuroVolumes() {
                    toUpdateWithPackageFiles.append((contentFile, mokuroVolumes.compactMap { mokuroVolume in
                        return mokuroVolume.contentPackageFile(forPackageContentFile: contentFile)
                    }))
                }
                
                if !(contentFile.imageUrl?.absoluteString.hasPrefix(contentFile.url.absoluteString.replacingOccurrences(of: "mokuro://mokuro/load/", with: "reader-file://file/load/") + "?subpath=") ?? false) {
                    if let imagePath = contentFile.packageFilePaths.lazy.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first(where: { path in
                        let path = path.lowercased()
                        return mokuroImageExtensions.contains(where: { path.hasSuffix("." + $0) })
                    }), let escapedPath = imagePath.addingPercentEncoding(withAllowedCharacters: subpathCharacterSet) {
                        let imageURL = contentFile.url.absoluteString.replacingOccurrences(of: "mokuro://mokuro/load/", with: "reader-file://file/load/") + "?subpath=" + escapedPath
                        if let imageURL = URL(string: imageURL) {
                            toUpdateWithImage.append((contentFile, imageURL))
                        }
                    }
                }
                
                let currentTitle = contentFile.title
                if currentTitle.isEmpty || currentTitle == contentFile.url.deletingPathExtension().lastPathComponent, let archive = try? contentFile.zipArchive(), let firstMokuro = contentFile.packageFilePaths.lazy.sorted().first(where: { $0.hasSuffix(".mokuro") }), let firstMokuroData = archive.data(for: firstMokuro), let title = (try? JSONSerialization.jsonObject(with: firstMokuroData) as? [String: Any])?["title"] as? String {
                    toUpdateWithTitle.append((contentFile, title))
                }
                
                if !contentFile.isPhysicalMedia {
                    toUpdateAsPhysicalMedia.append(contentFile)
                }
            }
            
            if !toUpdateWithImage.isEmpty || !toUpdateWithPackageFiles.isEmpty || !toUpdateWithTitle.isEmpty || !toUpdateAsPhysicalMedia.isEmpty {
                let realm = try await RealmBackgroundActor.shared.readerRealm
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for (contentFile, contentPackageFiles) in toUpdateWithPackageFiles {
                        for contentPackageFile in contentPackageFiles {
                            realm.add(contentPackageFile, update: .modified)
                        }
                    }
                    for (contentFile, imageURL) in toUpdateWithImage {
                        contentFile.imageUrl = imageURL
                    }
                    for (contentFile, title) in toUpdateWithTitle {
                        contentFile.title = title
                    }
                    for contentFile in toUpdateAsPhysicalMedia {
                        contentFile.isPhysicalMedia = true
                    }
                }
            }
        })
    }
}
