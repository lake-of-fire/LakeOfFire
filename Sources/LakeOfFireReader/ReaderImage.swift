import LakeOfFireWeb
import LakeOfFireFiles
import SwiftUI
import LakeOfFireContent
import LakeOfFireCore
import Nuke
import LakeImage
import CryptoKit

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

fileprivate let zipArchiveExtensions = ["zip", "epub"]

enum ReaderCoverRevisionError: Error, Equatable {
    case malformed
    case mismatch
}

struct ReaderPackagedImageRequest {
    let readerFileURL: URL
    private let subpath: String
    private let coverRevision: String?

    init?(url: URL) throws {
        guard url.scheme == "reader-file", url.host == "file",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        let revisions = queryItems.filter { $0.name == "cover-revision" }
        let coverRevision: String?
        if revisions.isEmpty {
            coverRevision = nil
        } else {
            guard revisions.count == 1, let revision = revisions.first?.value,
                  revision.utf8.count == 64,
                  revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ReaderCoverRevisionError.malformed
            }
            coverRevision = revision
        }
        guard let subpath = queryItems.first(where: { $0.name == "subpath" })?.value,
              let readerFileURL = url.deletingQuery else {
            if coverRevision != nil { throw ReaderCoverRevisionError.malformed }
            return nil
        }
        if coverRevision != nil, subpath.isEmpty { throw ReaderCoverRevisionError.malformed }
        self.subpath = subpath
        self.readerFileURL = readerFileURL
        self.coverRevision = coverRevision
    }

    static func imageURL(for url: URL) -> URL? {
        do {
            guard let request = try Self(url: url), request.coverRevision != nil else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            // Retire keys that could have cached bytes without checking their revision.
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "cover-validation" }
            items.append(URLQueryItem(name: "cover-validation", value: "1"))
            components.queryItems = items
            return components.url
        } catch {
            return nil
        }
    }

    func loadData(from fileURL: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard (try? isPackageFile(at: fileURL)) == true
                || (fileExists && isDirectory.boolValue)
                || zipArchiveExtensions.contains(readerFileURL.pathExtension.lowercased()) else { return nil }

        // Validate the existing receipt against the bytes admitted by the same bounded package reader.
        let source = try ReaderPackageEntrySource(localURL: fileURL, limits: .image)
        guard let data = try? source.readEntry(subpath: subpath) else { return nil }
        if let coverRevision {
            let actualRevision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actualRevision == coverRevision else { throw ReaderCoverRevisionError.mismatch }
        }
        return data
    }
}

fileprivate let readerImageProvider = CustomImageProvider { url in
    guard let request = try ReaderPackagedImageRequest(url: url) else { return nil }
    let fileURL = try ReaderFileManager.shared.localFileURL(forReaderFileURL: request.readerFileURL)
    return try request.loadData(from: fileURL)
}

public struct ReaderImage: View {
    let url: URL
    let contentMode: ContentMode
    /// An opt-in decode target measured in display points.
    var thumbnailSize: CGSize? = nil
    var maxWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    var maxHeight: CGFloat? = nil
    var cornerRadius: CGFloat? = nil
    
    public init(
        _ url: URL,
        contentMode: ContentMode = .fill,
        /// An opt-in decode target measured in display points.
        thumbnailSize: CGSize? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        cornerRadius: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.thumbnailSize = thumbnailSize
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.cornerRadius = cornerRadius
    }
    
    public var body: some View {
        if let imageURL = ReaderPackagedImageRequest.imageURL(for: url) {
            LakeImage(
                imageURL,
                contentMode: contentMode,
                thumbnailSize: thumbnailSize,
                maxWidth: maxWidth,
                minHeight: minHeight,
                maxHeight: maxHeight,
                cornerRadius: cornerRadius,
                imageProvider: readerImageProvider
            )
        } else {
            Color.clear.frame(maxWidth: maxWidth, maxHeight: maxHeight)
        }
    }
}

fileprivate func isPackageFile(at url: URL) throws -> Bool {
    let resourceValues = try url.resourceValues(forKeys: [.isPackageKey])
    return resourceValues.isPackage ?? false
}
