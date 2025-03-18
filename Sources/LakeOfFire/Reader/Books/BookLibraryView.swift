import SwiftUI
import SwiftUIWebView
import ReadiumOPDS
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import Combine
import UniformTypeIdentifiers
import LakeKit

public class BookLibraryModalsModel: ObservableObject {
    @Published var showingEbookCatalogs = false
    @Published var showingAddCatalog = false
    @Published var isImportingBookFile = false

    public init() { }
}

struct BookLibrarySheetsModifier: ViewModifier {
    let isActive: Bool
    @ObservedObject var bookLibraryModalsModel: BookLibraryModalsModel
    
    @StateObject private var opdsCatalogsViewModel = OPDSCatalogsViewModel()
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $bookLibraryModalsModel.showingEbookCatalogs.gatedBy(isActive)) {
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
                    .fileImporter(isPresented: $bookLibraryModalsModel.isImportingBookFile, allowedContentTypes: ReaderFileManager.shared.readerContentMimeTypes) { result in
                        Task { @MainActor in
                            switch result {
                            case .success(let url):
                                do {
                                    guard let importedFileURL = try await ReaderFileManager.shared.importFile(fileURL: url, fromDownloadURL: nil) else {
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
    func bookLibrarySheets(isActive: Bool, bookLibraryModalsModel: BookLibraryModalsModel) -> some View {
        modifier(
            BookLibrarySheetsModifier(
                isActive: isActive,
                bookLibraryModalsModel: bookLibraryModalsModel
            )
        )
    }
}

fileprivate struct EditorsPicksView: View {
    @StateObject var viewModel = BookLibraryViewModel()
    
    @ObservedObject private var downloadController = DownloadController.shared
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator

    var body: some View {
        if let errorMessage = viewModel.errorMessage {
            errorView(errorMessage: errorMessage)
        } else {
            editorsPicksView
        }
    }
    
    @ViewBuilder private var editorsPicksView: some View {
        HorizontalBooks(
            publications: viewModel.editorsPicks,
            isDownloadable: true) {
                selectedPublication,
                wasAlreadyDownloaded in
                if wasAlreadyDownloaded {
                    Task { @MainActor in
                        try await viewModel.open(
                            publication: selectedPublication,
                            readerFileManager: ReaderFileManager.shared,
                            readerPageURL: readerContent.pageURL,
                            navigator: navigator,
                            readerModeViewModel: readerModeViewModel
                        )
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
    @ObservedObject private var viewModel: BookLibraryViewModel

    public init (viewModel: BookLibraryViewModel) {
        self.viewModel = viewModel
    }
    
    @SceneStorage("bookFileEntrySelection") private var entrySelection: String?
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @StateObject private var readerContentListViewModel = ReaderContentListViewModel<ContentFile>()
    @State private var isEditorsPicksExpanded = true
    @State private var isMyBooksExpanded = true
    
    @ViewBuilder private var myBooksHeader: some View {
        VStack(alignment: .leading) {
            Text("My \(viewModel.mediaTypeTitle)")
            Button {
                bookLibraryModalsModel.isImportingBookFile.toggle()
            } label: {
                Label("Add \(viewModel.mediaFileTypeTitle)", systemImage: "plus.circle")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var myBooksSection: some View {
        ReaderContentListItems(
            viewModel: readerContentListViewModel,
            entrySelection: $entrySelection,
            alwaysShowThumbnails: false,
            showSeparators: false
        )
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
//        .navigationTitle("Books")
        .task { @MainActor in
            await viewModel.fetchAllData()
        }
        .refreshable {
            await viewModel.fetchAllData()
        }
        .task { @MainActor in
            if let files = readerFileManager.files(ofTypes: viewModel.fileTypes) {
                try? await readerContentListViewModel.load(contents: files, sortOrder: .createdAt, contentFilter: { contentFile in
                    guard let fileFilter = viewModel.fileFilter else { return true }
                    return try fileFilter(contentFile)
                })
            }
        }
        .onChange(of: readerFileManager.files(ofTypes: viewModel.fileTypes)) { ebookFiles in
            Task { @MainActor in
                if let ebookFiles {
                    try? await readerContentListViewModel.load(contents: ebookFiles, sortOrder: .createdAt)
                }
            }
        }
        .onChange(of: readerContentListViewModel.filteredContentIDs) { filteredFileIDs in
            guard let loadedFiles = viewModel.loadedFiles else { return }
            Task { @RealmBackgroundActor in
                guard !filteredFileIDs.isEmpty, let realmConfiguration = readerContentListViewModel.realmConfiguration else { return }
                let realm = await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await loadedFiles(filteredFileIDs.compactMap { realm?.object(ofType: ContentFile.self, forPrimaryKey: $0) })
            }
        }
    }
    
    public var body: some View {
        list
    }
}

@MainActor
public class BookLibraryViewModel: ObservableObject {
    let mediaTypeTitle: String
    let mediaFileTypeTitle: String
    let opdsURL: URL
    let fileTypes: [UTType]
    let fileFilter: ((ContentFile) throws -> Bool)?
    /// Loaded in RealmBackgroundActor
    let loadedFiles: (@RealmBackgroundActor ([ContentFile]) async throws -> Void)?

    public init(
        mediaTypeTitle: String = "Books",
        mediaFileTypeTitle: String = "EPUB",
        opdsURL: URL = URL(string: "https://reader.manabi.io/static/reader/books/opds/index.xml")!,
        fileTypes: [UTType] = [.epub, .epubZip],
        fileFilter: ((ContentFile) throws -> Bool)? = nil,
        loadedFiles: (@RealmBackgroundActor ([ContentFile]) async throws -> Void)? = nil
    ) {
        self.mediaTypeTitle = mediaTypeTitle
        self.mediaFileTypeTitle = mediaFileTypeTitle
        self.opdsURL = opdsURL
        self.fileTypes = fileTypes
        self.fileFilter = fileFilter
        self.loadedFiles = loadedFiles
    }
 
    @Published var editorsPicks: [Publication] = []
    @Published var errorMessage: String?
    private var cancellables = Set<AnyCancellable>()
    
    func fetchAllData() async {
        fetchEditorsPicks()
    }
    
    func fetchEditorsPicks() {
        Task {
            await fetchOPDSFeed(from: opdsURL)
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
    func open(
        publication: Publication,
        readerFileManager: ReaderFileManager = .shared,
        readerPageURL: URL,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel
    ) async throws {
        guard let downloadURL = publication.downloadURL else { return }
        guard let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title) else { return }

        var importedURL: URL?
        if await downloadable.existsLocally() {
            importedURL = try await readerFileManager.readerFileURL(for: downloadable)
        } else {
            guard let importedFileURL = try await readerFileManager.importFile(fileURL: downloadable.localDestination, fromDownloadURL: downloadable.url) else {
                print("Couldn't import \(publication.title) file URL")
                return
            }
            importedURL = importedFileURL
        }
        
        guard let toLoad = importedURL else { return }
        try await Task { @MainActor in
            guard let content = try await ReaderContentLoader.load(url: toLoad, persist: true, countsAsHistoryVisit: true), !content.url.matchesReaderURL(readerPageURL) else { return }
            try await navigator.load(
                content: content,
                readerFileManager: readerFileManager,
                readerModeViewModel: readerModeViewModel
            )
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
