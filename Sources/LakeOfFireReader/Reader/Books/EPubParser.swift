import Foundation
import LakeOfFireContent

struct EPubParser {
    /// Reads bounded XML metadata from a ZIP or unpacked EPUB. A cover is
    /// optional; malformed XML or an unsafe declared cover still rejects the
    /// result. Cancellation propagates rather than masquerading as bad input.
    static func parseMetadataAndCover(from epubURL: URL) throws -> (
        title: String, author: String?, coverHref: String?, publicationDate: Date?
    )? {
        try Task.checkCancellation()
        do {
            // Keep package-wide safety limits distinct from the smaller XML
            // entry budget. Images/audio are not metadata reads.
            let package = try ReaderPackageEntrySource(localURL: epubURL)
            _ = try package.enumerateEntries()
            let source = try ReaderPackageEntrySource(localURL: epubURL, limits: .metadata)
            let container = try source.readEntry(subpath: "META-INF/container.xml")
            guard let declaredPath = try EPubMetadataDocument.containerPath(container) else { return nil }
            let opfPath = try ReaderPackageEntrySource.sanitizeSubpath(declaredPath)
            let data = try source.readEntry(subpath: opfPath)
            guard let metadata = try EPubMetadataDocument.metadata(data) else { return nil }
            let coverHref: String?
            if let declaredCover = metadata.coverHref {
                guard let resolved = EPubMetadataDocument.coverPath(
                    baseDirectory: (opfPath as NSString).deletingLastPathComponent,
                    href: declaredCover
                ) else { return nil }
                coverHref = try ReaderPackageEntrySource.sanitizeSubpath(resolved)
            } else {
                coverHref = nil
            }
            try Task.checkCancellation()
            return (metadata.title, metadata.author, coverHref, metadata.publicationDate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

extension FileManager {
    /// Returns true if the URL points to a directory.
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return false
    }
}
