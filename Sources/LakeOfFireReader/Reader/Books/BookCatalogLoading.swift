import Foundation
import LakeOfFireOPDS
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BookCatalogLoadingError: LocalizedError {
    case noPublications
    case navigationCycle
    case navigationLimit
    case invalidNavigation

    var errorDescription: String? {
        switch self {
        case .noPublications: return "No publications or navigable links found."
        case .navigationCycle: return "The catalog links back to a document already visited."
        case .navigationLimit: return "The catalog requires too many navigation steps."
        case .invalidNavigation: return "Invalid 'All Books' URL."
        }
    }
}

/// Fetches the existing Editor's Picks/All Books route without recursive tasks.
/// It follows only the existing All Books route; purchase and sample links do
/// not become full-book downloads.
enum BookCatalogLoading {
    static func publications(
        from url: URL,
        session: URLSession = .shared,
        maximumDocuments: Int = 16
    ) async throws -> [Publication] {
        try Task.checkCancellation()
        guard maximumDocuments > 0 else { throw BookCatalogLoadingError.navigationLimit }
        var nextURL = url
        var visited = Set<URL>()
        for _ in 0..<maximumDocuments {
            try Task.checkCancellation()
            let requestedIdentity = documentIdentity(nextURL)
            guard visited.insert(requestedIdentity).inserted else {
                throw BookCatalogLoadingError.navigationCycle
            }
            let document = try await OPDSParser.parseURL(url: nextURL, session: session)
            try Task.checkCancellation()
            let finalIdentity = documentIdentity(document.documentURL)
            if finalIdentity != requestedIdentity, !visited.insert(finalIdentity).inserted {
                throw BookCatalogLoadingError.navigationCycle
            }
            if let publications = document.feed?.publications, !publications.isEmpty {
                return publications.map { publication($0, relativeTo: document.documentURL) }
            }
            if let standalone = document.publication {
                return [publication(standalone, relativeTo: document.documentURL)]
            }
            guard let link = document.feed?.navigation.first(where: { $0.title?.hasPrefix("All Books") == true }) else {
                throw BookCatalogLoadingError.noPublications
            }
            guard let resolved = link.url(relativeTo: document.documentURL), resolved.scheme != nil else {
                throw BookCatalogLoadingError.invalidNavigation
            }
            nextURL = resolved
        }
        throw BookCatalogLoadingError.navigationLimit
    }

    private static func documentIdentity(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func publication(_ value: LakeOfFireOPDS.Publication, relativeTo url: URL) -> Publication {
        let cover = value.images.first(withRel: .cover)
            ?? value.images.first(withRel: .opdsImage)
            ?? value.images.first(withRel: .opdsImageThumbnail)
        // A purchase/borrow/sample link is not a downloadable full publication.
        let acquisition = value.links.first(withRel: .opdsAcquisition)
            ?? value.links.first(withRel: .opdsAcquisitionOpenAccess)
        return Publication(
            title: value.metadata.title,
            author: value.metadata.authors.map(\.name).joined(separator: ", "),
            publicationDate: value.metadata.published,
            coverURL: cover?.url(relativeTo: url),
            downloadURL: acquisition?.url(relativeTo: url),
            summary: value.metadata.description ?? value.metadata.subtitle
        )
    }
}
