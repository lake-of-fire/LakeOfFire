import LakeOfFireFiles
import SwiftUI
import LakeOfFireContent
import Nuke
import LakeImage

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

fileprivate let readerImageProvider = CustomImageProvider { url in
    guard url.scheme == "reader-file" && url.host == "file" else { return nil }

    guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value else { return nil }

    guard let readerFileURL = url.deletingQuery else { return nil }
    let localPackageURL = try ReaderFileManager.shared.localFileURL(
        forReaderFileURL: readerFileURL
    )
    return try readerPackageImageData(
        localPackageURL: localPackageURL,
        subpath: subpathValue
    )
}

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
            imageProvider: readerImageProvider
        )
    }
}

func readerPackageImageData(
    localPackageURL: URL,
    subpath: String
) throws -> Data {
    let source = try ReaderPackageEntrySource(localURL: localPackageURL)
    return try source.readEntry(subpath: subpath)
}
