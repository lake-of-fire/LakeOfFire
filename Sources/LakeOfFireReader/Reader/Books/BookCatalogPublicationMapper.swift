import Foundation
import LakeOfFireOPDS

/// Converts a callback-owned OPDS graph to Reader's detached presentation values.
/// A nil result leaves navigation and empty-catalog handling with the loader.
enum BookCatalogPublicationMapper {
    static func publications(in document: ParseData) -> [LakeOfFireReader.Publication]? {
        let values: [LakeOfFireOPDS.Publication]
        if let publications = document.feed?.publications, !publications.isEmpty {
            values = publications
        } else if let standalone = document.publication {
            values = [standalone]
        } else {
            return nil
        }

        return values.map { publication($0, relativeTo: document.documentURL) }
    }

    private static func publication(
        _ value: LakeOfFireOPDS.Publication,
        relativeTo documentURL: URL
    ) -> LakeOfFireReader.Publication {
        let cover = value.images.first(withRel: .cover)
            ?? value.images.first(withRel: .opdsImage)
            ?? value.images.first(withRel: .opdsImageThumbnail)
        // Preserve generic acquisition priority. Only this exact full-book
        // fallback is eligible; buy, borrow, sample and subscribe are distinct.
        let acquisition = value.links.first(withRel: .opdsAcquisition)
            ?? value.links.first(withRel: .opdsAcquisitionOpenAccess)
        return LakeOfFireReader.Publication(
            title: value.metadata.title,
            author: value.metadata.authors.map(\.name).joined(separator: ", "),
            publicationDate: value.metadata.published,
            coverURL: cover?.url(relativeTo: documentURL),
            downloadURL: acquisition?.url(relativeTo: documentURL),
            summary: value.metadata.description ?? value.metadata.subtitle
        )
    }
}
