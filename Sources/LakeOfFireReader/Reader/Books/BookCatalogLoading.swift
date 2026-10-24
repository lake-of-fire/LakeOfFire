import Foundation
import LakeOfFireOPDS
import SwiftUIWebView
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BookCatalogLoadingError: LocalizedError, Sendable {
    case noPublications
    case navigationCycle
    case navigationLimit
    case invalidNavigation
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPublications: return "No publications or navigable links found"
        case .navigationCycle: return "The catalog links back to a document already visited."
        case .navigationLimit: return "The catalog requires too many navigation steps."
        case .invalidNavigation: return "Invalid 'All Books' URL"
        case let .fetchFailed(message): return "Failed to fetch data: \(message)"
        }
    }
}

/// Follows the existing All Books route in the caller's task. The callback
/// transport may finish after cancellation; it cannot start another hop then.
enum BookCatalogLoading {
    private enum Content: Sendable {
        case publications([Publication])
        case navigation(URL)
        case failure(BookCatalogLoadingError)
    }

    private struct Document: Sendable {
        let finalURL: URL?
        let content: Content
    }

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
            let document = await fetchDocument(from: nextURL, session: session)
            try Task.checkCancellation()
            if let finalURL = document.finalURL {
                let finalIdentity = documentIdentity(finalURL)
                if finalIdentity != requestedIdentity, !visited.insert(finalIdentity).inserted {
                    throw BookCatalogLoadingError.navigationCycle
                }
            }
            switch document.content {
            case let .publications(publications):
                return publications
            case let .navigation(url):
                nextURL = url
            case let .failure(error):
                throw error
            }
        }
        throw BookCatalogLoadingError.navigationLimit
    }

    private static func fetchDocument(from url: URL, session: URLSession) async -> Document {
        await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: url, session: session) { parseData, error in
                if let error {
                    continuation.resume(returning: Document(
                        finalURL: nil, content: .failure(.fetchFailed(error.localizedDescription))
                    ))
                    return
                }
                // Consume the mutable OPDS graph on its callback. Only mapped
                // values cross the continuation back into the traversal task.
                let content: Content
                if let publications = parseData?.feed?.publications, !publications.isEmpty {
                    content = .publications(publications.map { publication($0, relativeTo: url) })
                } else if let allBooksLink = parseData?.feed?.navigation.first(where: {
                    $0.title?.hasPrefix("All Books") == true
                }) {
                    if let nextURL = allBooksLink.url(relativeTo: url.domainURL) ?? URL(string: allBooksLink.href) {
                        content = .navigation(nextURL)
                    } else {
                        content = .failure(.invalidNavigation)
                    }
                } else {
                    content = .failure(.noPublications)
                }
                continuation.resume(returning: Document(finalURL: parseData?.documentURL, content: content))
            }
        }
    }

    private static func documentIdentity(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func publication(_ publication: LakeOfFireOPDS.Publication, relativeTo url: URL) -> Publication {
        let coverLink = publication.images.first(withRel: .cover) ?? publication.images.first(withRel: .opdsImage) ?? publication.images.first(withRel: .opdsImageThumbnail)
        let acquisitionLink = publication.links.first(withRel: .opdsAcquisition)
        let summary = publication.metadata.description ?? publication.metadata.subtitle
        return Publication(
            title: publication.metadata.title,
            author: publication.metadata.authors.map(\.name).joined(separator: ", "),
            publicationDate: publication.metadata.published,
            coverURL: coverLink?.url(relativeTo: url.domainURL),
            downloadURL: acquisitionLink?.url(relativeTo: url.domainURL),
            summary: summary
        )
    }
}
