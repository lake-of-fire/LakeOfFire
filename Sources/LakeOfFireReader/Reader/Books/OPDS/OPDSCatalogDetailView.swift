import SwiftUI

@MainActor
struct OPDSCatalogDetailView: View {
    let catalogURL: String
    @State private var publications: [Publication] = []
    @State private var errorMessage: String?
    @State private var refresh = BookCatalogRefresh()

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("OPDSCatalog.Error")
                Button("Retry") { startFetch() }
                    .accessibilityIdentifier("OPDSCatalog.Retry")
            }
            ForEach(publications) { publication in
                Text(publication.title)
            }
        }
        .navigationTitle("Catalog Details")
        .task(id: catalogURL) { await load() }
        .refreshable { await load() }
        .onDisappear { refresh.cancel() }
    }

    private func load() async {
        let url = catalogURL
        await refresh.load(
            fetch: { await Self.fetch(url) },
            publish: { publications = $0; errorMessage = $1 }
        )
    }

    private func startFetch() {
        let url = catalogURL
        refresh.start(
            fetch: { await Self.fetch(url) },
            publish: { publications = $0; errorMessage = $1 }
        )
    }

    private static func fetch(_ rawURL: String) async -> ([Publication], String?) {
        guard let url = URL(string: rawURL), url.scheme != nil else {
            return ([], "Invalid catalog URL")
        }
        do {
            return (try await BookCatalogLoading.publications(from: url), nil)
        } catch {
            return ([], "Failed to fetch catalog data: \(error.localizedDescription)")
        }
    }
}
