import SwiftUI
import SwiftUIWebView
import ReadiumOPDS
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import Combine
import LakeKit

public class BookLibraryModalsModel: ObservableObject {
    @Published var showingEbookCatalogs = false
    @Published var showingAddCatalog = false
    @Published var isImportingBookFile = false
    
    public init() { }
}

struct BookLibrarySheetsModifier: ViewModifier {
    @ObservedObject var bookLibraryModalsModel: BookLibraryModalsModel
    let isActive: Bool
    
    @StateObject private var opdsCatalogsViewModel = OPDSCatalogsViewModel()
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $bookLibraryModalsModel.showingEbookCatalogs) {
                if #available(iOS 16, macOS 13, *) {
                    NavigationStack {
                        OPDSCatalogsView()
                    }
                    .sheet(isPresented: $bookLibraryModalsModel.showingAddCatalog) {
                        AddCatalogView()
                    }
                }
            }
            .environmentObject(opdsCatalogsViewModel)
            .background {
                // Weird hack because stacking fileImporter breaks all of them
                Color.clear
                    .fileImporter(isPresented: $bookLibraryModalsModel.isImportingBookFile, allowedContentTypes: [.epub, .epubZip, .directory]) { result in
                        Task { @MainActor in
                            switch result {
                            case .success(let url):
                                do {
                                    guard let importedFileURL = try await readerFileManager.importFile(fileURL: url, fromDownloadURL: nil, restrictToReaderContentMimeTypes: true) else {
                                        print("Couldn't import \(url.absoluteString)")
                                        return
                                    }
                                } catch {
                                    print("Couldn't import \(url.absoluteString): \(error)")
                                    return
                                }
                            case .failure(let error):
                                print(error)
                            }
                        }
                    }
            }
    }
}

public extension View {
    func bookLibrarySheets(bookLibraryModalsModel: BookLibraryModalsModel, isActive: Bool) -> some View {
        modifier(BookLibrarySheetsModifier(bookLibraryModalsModel: bookLibraryModalsModel, isActive: isActive))
    }
}

fileprivate struct EditorsPicksView: View {
    @StateObject var viewModel = BookLibraryViewModel()
    
    @ObservedObject private var downloadController = DownloadController.shared
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @Environment(\.readerPageURL) private var readerPageURL
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator

    var body: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                errorView(errorMessage: errorMessage)
            } else {
                editorsPicksView
            }
        }
    }
    
    @ViewBuilder private var editorsPicksView: some View {
        HorizontalBooks(
            publications: viewModel.editorsPicks,
            isDownloadable: true) { selectedPublication, wasAlreadyDownloaded in
                if wasAlreadyDownloaded {
                    Task { @MainActor in
                        try await viewModel.open(publication: selectedPublication, readerFileManager: readerFileManager, readerPageURL: readerPageURL, navigator: navigator)
                    }
                }
            }
    }
    
    @ViewBuilder private func errorView(errorMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Error: \(errorMessage)")
                .foregroundColor(.red)
            Button("Retry") {
                viewModel.fetchEditorsPicks()
            }
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct BookLibraryView: View {
    @StateObject private var viewModel = BookLibraryViewModel()
    @SceneStorage("bookFileEntrySelection") private var entrySelection: String?
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @StateObject private var readerContentListViewModel = ReaderContentListViewModel<ContentFile>()
    @State private var isEditorsPicksExpanded = true
    @State private var isMyBooksExpanded = true
    
    @ViewBuilder private var myBooksHeader: some View {
        VStack(alignment: .leading) {
            Text("My Books")
            Button {
                bookLibraryModalsModel.isImportingBookFile.toggle()
            } label: {
                Label("Add EPUB", systemImage: "plus.circle")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var myBooksSection: some View {
        ReaderContentListItems(viewModel: readerContentListViewModel, entrySelection: $entrySelection, alwaysShowThumbnails: false, showSeparators: false)
            .listRowSeparatorIfAvailable(.hidden)
    }

    @ViewBuilder var list: some View {
        List(selection: $entrySelection) {
//
//            Button("Catalogs") {
//                // Implementation remains unchanged
//            }
            
            // Section for User Library can be implemented similarly
            if #available(iOS 17, macOS 14.0, *) {
                Section(isExpanded: $isMyBooksExpanded) {
                    myBooksSection
                } header: {
                    myBooksHeader
                }
            } else {
                Section {
                    myBooksSection
                } header: {
                    myBooksHeader
                }
            }
            
            if #available(iOS 17, macOS 14.0, *) {
                Section("Editor's Picks", isExpanded: $isEditorsPicksExpanded) {
                    EditorsPicksView(viewModel: viewModel)
                }
            } else {
                Section("Editor's Picks") {
                    EditorsPicksView(viewModel: viewModel)
                }
            }
        }
#if os(iOS)
        .listStyle(.sidebar)
#endif
        .scrollContentBackgroundIfAvailable(.hidden)
//        .listRowSeparatorIfAvailable(.visible)
        .navigationTitle("Books")
        .task { @MainActor in
            await viewModel.fetchAllData()
        }
        .refreshable {
            await viewModel.fetchAllData()
        }
        .task(id: readerFileManager.ubiquityContainerIdentifier) {
            try? await readerFileManager.refreshAllFilesMetadata()
        }
        .task { @MainActor in
            if let ebookFiles = readerFileManager.ebookFiles {
                try? await readerContentListViewModel.load(contents: ebookFiles, sortOrder: .createdAt)
            }
        }
        .onChange(of: readerFileManager.ebookFiles) { ebookFiles in
            Task { @MainActor in
                if let ebookFiles = readerFileManager.ebookFiles {
                    try? await readerContentListViewModel.load(contents: ebookFiles, sortOrder: .createdAt)
                }
            }
        }
    }
    
    public var body: some View {
        list
    }
    
    public init() { }
}

@MainActor
class BookLibraryViewModel: ObservableObject {
    @Published var editorsPicks: [Publication] = []
    @Published var errorMessage: String?
    private var cancellables = Set<AnyCancellable>()
    
    func fetchAllData() async {
        fetchEditorsPicks()
    }
    
    func fetchEditorsPicks() {
        let urlString = "https://reader.manabi.io/static/reader/books/opds/index.xml"
        guard let url = URL(string: urlString) else {
            Task { @MainActor in
                self.errorMessage = "Invalid URL"
            }
            return
        }
        
        Task {
            await fetchOPDSFeed(from: url)
        }
    }
    
    private func fetchOPDSFeed(from url: URL) async {
        await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: url) { parseData, error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        self.errorMessage = "Failed to fetch data: \(error.localizedDescription)"
                        continuation.resume()
                        return
                    }
                    
                    if let publications = parseData?.feed?.publications, !publications.isEmpty {
                        self.editorsPicks = publications.map {
                            let coverLink = $0.images.first(withRel: .cover) ?? $0.images.first(withRel: .opdsImage) ?? $0.images.first(withRel: .opdsImageThumbnail)
                            return Publication(
                                title: $0.metadata.title,
                                author: $0.metadata.authors.map { $0.name } .joined(separator: ", "),
                                publicationDate: $0.metadata.published,
                                coverURL: coverLink?.url(relativeTo: url.domainURL),
                                downloadURL: $0.links.first(withRel: .opdsAcquisition)?.url(relativeTo: url.domainURL))
                        }
                        continuation.resume()
                    } else if let navigationLinks = parseData?.feed?.navigation, let allBooksLink = navigationLinks.first(where: { $0.title?.hasPrefix("All Books") == true }) {
                        guard let allBooksURL = URL(string: allBooksLink.href) else {
                            self.errorMessage = "Invalid 'All Books' URL"
                            continuation.resume()
                            return
                        }
                        
                        // Fetch the "All Books" feed recursively
                        await fetchOPDSFeed(from: allBooksURL)
                        continuation.resume()
                    } else {
                        self.errorMessage = "No publications or navigable links found"
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    @RealmBackgroundActor
    func open(publication: Publication, readerFileManager: ReaderFileManager, readerPageURL: URL, navigator: WebViewNavigator) async throws {
        guard let downloadURL = publication.downloadURL else { return }
        guard let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title) else { return }

        var importedURL: URL?
        if await downloadable.existsLocally() {
            importedURL = try await readerFileManager.readerFileURL(for: downloadable)
        } else {
            guard let importedFileURL = try await readerFileManager.importFile(fileURL: downloadable.localDestination, fromDownloadURL: downloadable.url, restrictToReaderContentMimeTypes: true) else {
                print("Couldn't import \(publication.title) file URL")
                return
            }
            importedURL = importedFileURL
        }
        
        guard let toLoad = importedURL else { return }
        try await Task { @MainActor in
            guard let content = try await ReaderContentLoader.load(url: toLoad, persist: true, countsAsHistoryVisit: true), !content.url.matchesReaderURL(readerPageURL) else { return }
            await navigator.load(content: content, readerFileManager: readerFileManager)
        }.value
    }
}

public struct Publication: Identifiable, Hashable {
    public let id = UUID()
    public var title: String
    public var author: String?
    public var publicationDate: Date?
    public var coverURL: URL?
    public var downloadURL: URL?
}
