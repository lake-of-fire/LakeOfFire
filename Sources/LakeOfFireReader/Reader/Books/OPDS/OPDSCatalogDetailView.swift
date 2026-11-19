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

    @Published private(set) var publications: [Publication] = []
    @Published private(set) var errorMessage: String?

    var publicationFetcher: Fetcher = {
        await BookLibraryViewModel.fetchPublications(from: $0)
    }
    private let refresh = BookCatalogRefresh()

    func load(catalogURL: String) async {
        await refresh.load(
            fetch: capturedFetch(catalogURL: catalogURL),
            publish: { [weak self] in self?.publish($0, error: $1) }
        )
    }

    @discardableResult
    func retry(catalogURL: String) -> Task<Void, Never>? {
        refresh.start(
            fetch: capturedFetch(catalogURL: catalogURL),
            publish: { [weak self] in self?.publish($0, error: $1) }
        )
    }

    func cancel() {
        refresh.cancel()
    }

    private func capturedFetch(
        catalogURL: String
    ) -> @MainActor () async -> ([Publication], String?) {
        let fetcher = publicationFetcher
        return {
            guard let url = URL(string: catalogURL), url.scheme != nil else {
                return ([], "Invalid catalog URL")
            }
            return await fetcher(url)
        }
    }

    private func publish(_ publications: [Publication], error: String?) {
        self.publications = publications
        errorMessage = error
    }
}
