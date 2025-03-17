import SwiftUI
import ZIPFoundation
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

public struct ReaderImage: View {
    let url: URL
    let contentMode: ContentMode
    var maxWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    var maxHeight: CGFloat? = nil
    var cornerRadius: CGFloat? = nil
    
    public init(
        _ url: URL,
        contentMode: ContentMode = .fill,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        cornerRadius: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.cornerRadius = cornerRadius
    }
    
    public var body: some View {
        LakeImage(
            url,
            contentMode: contentMode,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            cornerRadius: cornerRadius,
            imageProvider: { url in
                guard url.scheme == "reader-file" && url.host == "file" else { return nil }
                
                guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value else { return nil }
                
                if FileManager.default.isDirectory(url) {
                    let filePath = url.appendingPathComponent(subpathValue)
                    return try? Data(contentsOf: filePath)
                }
                
                guard zipArchiveExtensions.contains(url.pathExtension.lowercased()) else { return nil }
                guard let readerFileURL = url.deletingQuery else { return nil }
                let fileURL = try ReaderFileManager.shared.localFileURL(forReaderFileURL: readerFileURL)
                guard let archive = try Archive(url: fileURL, accessMode: .read) else { return nil }
                guard let entry = archive[subpathValue], entry.type == .file else { return nil }
                var imageData = Data()
                try archive.extract(entry, consumer: { imageData.append($0) })
                return imageData
            }
        )
    }
}
