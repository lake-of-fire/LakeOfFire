@preconcurrency import Combine
import SwiftUI

@MainActor
struct OPDSCatalogDetailView: View {
    let catalogURL: String
    @StateObject private var viewModel = OPDSCatalogDetailViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("OPDSCatalog.Error")
                Button("Retry") { viewModel.retry(catalogURL: catalogURL) }
                    .accessibilityIdentifier("OPDSCatalog.Retry")
            }
            ForEach(viewModel.publications) { publication in
                Text(publication.title)
            }
            if let pageErrorMessage = viewModel.pageErrorMessage {
                Text(pageErrorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("OPDSCatalog.PageError")
            }
            if viewModel.isLoadingNextPage {
                ProgressView("Loading more books")
            } else if viewModel.canLoadMore {
                Button(viewModel.pageErrorMessage == nil ? "Load More" : "Retry Loading More") {
                    viewModel.loadMore()
                }
                .accessibilityIdentifier("OPDSCatalog.LoadMore")
            }
        }
        .navigationTitle("Catalog Details")
        .task(id: catalogURL) { await viewModel.load(catalogURL: catalogURL) }
        .refreshable { await viewModel.load(catalogURL: catalogURL) }
        .onDisappear { viewModel.cancel() }
    }
}

/// The detail sheet owns its catalog refresh and reuses the library's structured
/// producer. A completed old URL cannot replace a newer detail or Retry result.
@MainActor
final class OPDSCatalogDetailViewModel: ObservableObject {
    typealias Fetcher = @MainActor (URL) async -> ([Publication], String?)
    typealias PageFetcher = @MainActor (BookCatalogPageRequest) async -> BookCatalogPageLoad

    private struct Cursor {
        let url: URL
        let visited: Set<URL>
        let fetch: PageFetcher

        init?(_ page: BookCatalogPage, fetch: @escaping PageFetcher) {
            guard let url = page.nextURL else { return nil }
            self.url = url
            visited = page.visited
            self.fetch = fetch
        }
    }

    private struct Presentation {
        var publications: [Publication] = []
        var errorMessage: String?
        var pageErrorMessage: String?
        var isLoadingNextPage = false
        var cursor: Cursor?
    }

    nonisolated let objectWillChange = ObservableObjectPublisher()
    private var presentation = Presentation()
    private var presentationRevision: UInt64 = 0
    private var isNotifying = false

    var publications: [Publication] { presentation.publications }
    var errorMessage: String? { presentation.errorMessage }
    var pageErrorMessage: String? { presentation.pageErrorMessage }
    var isLoadingNextPage: Bool { presentation.isLoadingNextPage }
    var canLoadMore: Bool { presentation.cursor != nil }

    var publicationFetcher: Fetcher?
    var pageFetcher: PageFetcher = {
        await BookLibraryViewModel.fetchCatalogPage($0)
    }
    private let refresh = BookCatalogRefresh()

    func load(catalogURL: String) async {
        guard let task = retry(catalogURL: catalogURL) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func retry(catalogURL: String) -> Task<Void, Never>? {
        let fetch = capturedPageFetcher()
        guard let task = refresh.startPage(
            fetch: {
                guard let url = URL(string: catalogURL), url.scheme != nil else {
                    return .failure("Invalid catalog URL")
                }
                return await fetch(.first(url))
            },
            publish: { [weak self] result in self?.publishFirstPage(result, fetch: fetch) }
        ) else { return nil }
        resetContinuation()
        return task
    }

    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isNotifying, !isLoadingNextPage, let cursor = presentation.cursor else { return nil }
        guard let task = refresh.startPage(
            fetch: { await cursor.fetch(.next(cursor.url, visited: cursor.visited)) },
            publish: { [weak self] result in self?.publishNextPage(result, cursor: cursor) },
            onFinish: { [weak self] in
                guard let self, self.isLoadingNextPage else { return }
                self.updatePresentation { $0.isLoadingNextPage = false }
            }
        ) else { return nil }
        updatePresentation {
            $0.isLoadingNextPage = true
            $0.pageErrorMessage = nil
        }
        return task
    }

    func cancel() {
        refresh.cancel()
        resetContinuation()
    }

    private func resetContinuation() {
        updatePresentation {
            $0.cursor = nil
            $0.pageErrorMessage = nil
            $0.isLoadingNextPage = false
        }
    }

    private func updatePresentation(
        onlyWhileTaskIsActive: Bool = false, _ update: (inout Presentation) -> Void
    ) {
        var next = presentation
        update(&next)
        presentationRevision &+= 1
        let revision = presentationRevision
        // A synchronous subscriber can dismiss or replace the catalog.
        // Let that newer presentation commit without recursively notifying
        // observers who are already handling this change.
        if !isNotifying {
            isNotifying = true
            objectWillChange.send()
            isNotifying = false
        }
        guard presentationRevision == revision, !onlyWhileTaskIsActive || !Task.isCancelled else { return }
        presentation = next
    }

    private func capturedPageFetcher() -> PageFetcher {
        guard let publicationFetcher else { return pageFetcher }
        // Preserve single-response providers. They have no continuation cursor.
        return { request in
            let (publications, error) = await publicationFetcher(request.url)
            if let error { return .failure(error) }
            return .page(BookCatalogPage(publications: publications))
        }
    }

    private func publishFirstPage(_ result: BookCatalogPageLoad, fetch: @escaping PageFetcher) {
        switch result {
        case let .page(page):
            updatePresentation(onlyWhileTaskIsActive: true) {
                $0.publications = page.publications
                $0.errorMessage = nil
                $0.cursor = Cursor(page, fetch: fetch)
            }
        case let .failure(error):
            publishFirstPageError(error)
        case .cycle:
            publishFirstPageError(BookCatalogPageLoad.cycleMessage)
        case .cancelled:
            break
        }
    }

    private func publishFirstPageError(_ error: String) {
        updatePresentation(onlyWhileTaskIsActive: true) {
            $0.publications = []
            $0.errorMessage = error
        }
    }

    private func publishNextPage(_ result: BookCatalogPageLoad, cursor: Cursor) {
        updatePresentation(onlyWhileTaskIsActive: true) { presentation in
            presentation.isLoadingNextPage = false
            switch result {
            case let .page(page):
                let additions = Self.newPublications(
                    page.publications, after: presentation.publications
                )
                presentation.publications.append(contentsOf: additions)
                presentation.cursor = Cursor(page, fetch: cursor.fetch)
            case let .failure(error):
                presentation.pageErrorMessage = error
            case .cycle:
                presentation.pageErrorMessage = BookCatalogPageLoad.cycleMessage
                // A continuation redirected to an admitted document. Stop
                // here; refreshing the catalog can establish a new cursor.
                presentation.cursor = nil
            case .cancelled:
                break
            }
        }
    }

    private static func newPublications(_ incoming: [Publication], after publications: [Publication]) -> [Publication] {
        func identifier(_ publication: Publication) -> String? {
            guard let raw = publication.catalogIdentifier else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        var identifiers = Set(publications.compactMap { identifier($0) })
        var acquisitionURLs = Set(publications.compactMap(\.downloadURL))
        var unidentifiedAcquisitionURLs = Set(publications.compactMap { publication in
            identifier(publication) == nil ? publication.downloadURL : nil
        })
        var additions: [Publication] = []
        for publication in incoming {
            let id = identifier(publication)
            let url = publication.downloadURL
            if let id, identifiers.contains(id) { continue }
            if let url, (id == nil ? acquisitionURLs : unidentifiedAcquisitionURLs).contains(url) { continue }
            if let id { identifiers.insert(id) }
            if let url {
                acquisitionURLs.insert(url)
                if id == nil { unidentifiedAcquisitionURLs.insert(url) }
            }
            additions.append(publication)
        }
        return additions
    }
}
