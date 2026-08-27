import LakeOfFireWeb
import LakeOfFireFiles
import SwiftUI
import LakeOfFireContent
import LakeOfFireCore
import Nuke
import LakeImage

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

fileprivate let zipArchiveExtensions = ["zip", "epub"]

fileprivate let readerImageProvider = CustomImageProvider { url in
    guard url.scheme == "reader-file" && url.host == "file" else { return nil }

    guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value else { return nil }

    guard let readerFileURL = url.deletingQuery else { return nil }
    let fileURL = try ReaderFileManager.shared.localFileURL(forReaderFileURL: readerFileURL)

    var isDirectory: ObjCBool = false
    let fileExists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
    guard (try? isPackageFile(at: fileURL)) == true
            || (fileExists && isDirectory.boolValue)
            || zipArchiveExtensions.contains(url.pathExtension.lowercased()) else {
        return nil
    }

    // Package entries are untrusted input. ReaderPackageEntrySource validates
    // the subpath and enforces both advertised and actual decompressed-byte
    // limits before returning image data, for directories as well as ZIPs.
    let source = try ReaderPackageEntrySource(localURL: fileURL, limits: .image)
    return try? source.readEntry(subpath: subpathValue)
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
        LakeImage(
            url,
            contentMode: contentMode,
            thumbnailSize: thumbnailSize,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            cornerRadius: cornerRadius,
            imageProvider: readerImageProvider
        )
    }
}

fileprivate func isPackageFile(at url: URL) throws -> Bool {
    let resourceValues = try url.resourceValues(forKeys: [.isPackageKey])
    return resourceValues.isPackage ?? false
}
