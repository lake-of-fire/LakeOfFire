import SwiftUI
import LakeOfFireContent
import SwiftUIWebView

@MainActor
struct OPDSCatalogDetailView: View {
    let catalogURL: String
    var onNavigateToReader: (() -> Void)? = nil
    @StateObject private var viewModel = OPDSCatalogDetailViewModel()
    @State private var openError: String?
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webViewNavigator) private var navigator

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("OPDSCatalog.Error")
                Button("Retry") { viewModel.retry(catalogURL: catalogURL) }
                    .accessibilityIdentifier("OPDSCatalog.Retry")
            }
            if let openError {
                Text(openError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("OPDSCatalog.OpenError")
            }
            ForEach(viewModel.publications) { publication in
                BookListRow(
                    publication: publication,
                    selectionOwner: viewModel.selectionOwner,
                    onSelected: { wasAlreadyDownloaded, selection in
                        guard wasAlreadyDownloaded else { return }
                        await openDownloaded(publication, selection: selection)
                    },
                    onNavigateToReader: didOpenBook
                )
            }
        }
        .navigationTitle("Catalog Details")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: catalogURL) {
            guard !Task.isCancelled else { return }
            viewModel.selectionOwner.cancelOpenSelection()
            openError = nil
            await viewModel.load(catalogURL: catalogURL)
        }
        .refreshable { await viewModel.load(catalogURL: catalogURL) }
        .onDisappear { viewModel.cancel() }
    }

    private func openDownloaded(_ publication: Publication, selection: BookLibraryViewModel.OpenSelection) async {
        let owner = viewModel.selectionOwner
        guard owner.isCurrentOpenSelection(selection) else { return }
        openError = nil
        do {
            try await BookLibraryViewModel.openDownloaded(
                publication: publication,
                readerContent: readerContent,
                navigator: navigator,
                readerModeViewModel: readerModeViewModel,
                shouldOpen: { owner.isCurrentOpenSelection(selection) },
                onNavigateToReader: didOpenBook
            )
        } catch {
            guard owner.isCurrentOpenSelection(selection) else { return }
            openError = BookDownloadOpenFailurePresentation.message(for: error, title: publication.title)
        }
    }

    private func didOpenBook() {
        dismiss()
        bookLibraryModalsModel.showingEbookCatalogs = false
        onNavigateToReader?()
    }
}

/// The detail sheet owns its catalog refresh and reuses the library's structured
/// producer. A completed old URL cannot replace a newer detail or Retry result.
@MainActor
final class OPDSCatalogDetailViewModel: ObservableObject {
    typealias Fetcher = @MainActor (URL) async -> ([Publication], String?)

    @Published private(set) var publications: [Publication] = []
    @Published private(set) var errorMessage: String?
    let selectionOwner = BookLibraryViewModel()

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
        selectionOwner.cancelOpenSelection()
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
