import Foundation
import LakeOfFireContent

struct EPubParser {
    static func parseMetadataAndCover(
        from epubURL: URL,
        limits: ReaderPackageResourceLimits = .metadata
    ) throws -> (title: String, author: String?, coverHref: String?, publicationDate: Date?)? {
        let source = try ReaderPackageEntrySource(localURL: epubURL, limits: limits)
        // Bound catalog inspection separately from the metadata bytes read below.
        // Unrequested media does not inherit the per-entry metadata read cap.
        _ = try source.enumerateEntries()
        let containerData = try source.readEntry(subpath: "META-INF/container.xml")
        guard let declaredPath = try EPubMetadataDocument.containerPath(containerData),
              let packagePath = ReaderPackageEntrySource.resolveSubpath(declaredPath, relativeTo: "") else { return nil }
        let packageData = try source.readEntry(subpath: packagePath)
        guard let metadata = try EPubMetadataDocument.metadata(packageData) else { return nil }

        let packageDirectory = (packagePath as NSString).deletingLastPathComponent
        let coverHref = metadata.coverHref.flatMap {
            EPubMetadataDocument.coverPath(baseDirectory: packageDirectory, href: $0)
        }
        return (
            title: metadata.title,
            author: metadata.author,
            coverHref: coverHref,
            publicationDate: metadata.publicationDate
        )
    }

}
