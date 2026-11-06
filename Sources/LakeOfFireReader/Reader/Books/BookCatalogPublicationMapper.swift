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
        let coverURL = value.images.first(withRel: .cover)?.url(relativeTo: documentURL)
            ?? value.images.first(withRel: .opdsImage)?.url(relativeTo: documentURL)
            ?? value.images.first(withRel: .opdsImageThumbnail)?.url(relativeTo: documentURL)
            // OPDS 2.0 images already identify visual representations;
            // the collection's links do not require legacy image relations.
            ?? value.images.lazy.compactMap { $0.url(relativeTo: documentURL) }.first
        // Preserve generic acquisition priority. Only this exact full-book
        // fallback is eligible; buy, borrow, sample and subscribe are distinct.
        let acquisition = value.links.first(withRel: .opdsAcquisition)
            ?? value.links.first(withRel: .opdsAcquisitionOpenAccess)
        return LakeOfFireReader.Publication(
            title: value.metadata.title,
            author: value.metadata.authors.map(\.name).joined(separator: ", "),
            publicationDate: value.metadata.published,
            coverURL: coverURL,
            downloadURL: acquisition?.url(relativeTo: documentURL),
            summary: value.metadata.description ?? value.metadata.subtitle
        )
    }
}
