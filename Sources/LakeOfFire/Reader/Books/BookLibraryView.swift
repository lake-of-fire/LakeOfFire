import SwiftUI
import SwiftUIWebView
import LakeOfFireOPDS
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import Combine
import UniformTypeIdentifiers
import LakeKit

@MainActor
public class BookLibraryModalsModel: ObservableObject {
    @Published public var showingEbookCatalogs = false
    @Published public var showingAddCatalog = false
    @Published public var isImportingBookFile = false

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
                Color.clear
                    .fileImporter(isPresented: $bookLibraryModalsModel.isImportingBookFile, allowedContentTypes: ReaderFileManager.shared.readerContentMimeTypes) { result in
                        Task { @MainActor in
                            switch result {
                            case .success(let url):
                                do {
                                    guard let _ = try await ReaderFileManager.shared.importFile(fileURL: url, fromDownloadURL: nil) else {
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
        modifier(BookLibrarySheetsModifier(isActive: isActive, bookLibraryModalsModel: bookLibraryModalsModel))
    }
}

fileprivate struct EditorsPicksView: View {
    @ObservedObject var viewModel: BookLibraryViewModel

    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator

    var body: some View {
        if let errorMessage = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                Button("Retry") {
                    viewModel.fetchEditorsPicks()
                }
            }
        } else if !viewModel.editorsPicks.isEmpty {
            ForEach(viewModel.editorsPicks) { publication in
                BookListRow(
                    publication: publication,
                    onSelected: { wasAlreadyDownloaded in
                        guard wasAlreadyDownloaded else { return }
                        Task { @MainActor in
                            try await viewModel.open(
                                publication: publication,
                                readerFileManager: ReaderFileManager.shared,
                                readerPageURL: readerContent.pageURL,
                                navigator: navigator,
                                readerModeViewModel: readerModeViewModel
                            )
                        }
                    },
                    onNavigateToReader: viewModel.onNavigateToReader
                )
            }
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct BookLibraryView: View {
    @ObservedObject private var viewModel: BookLibraryViewModel
    private let showsInlineAddButton: Bool

    public init(viewModel: BookLibraryViewModel, showsInlineAddButton: Bool = true) {
        self.viewModel = viewModel
        self.showsInlineAddButton = showsInlineAddButton
    }

    @SceneStorage("bookFileEntrySelection") private var entrySelection: String?

    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager

    @StateObject private var readerContentListViewModel = ReaderContentListViewModel<ContentFile>()
    @AppStorage("BookLibraryView.editorsPicks.isExpanded") private var isEditorsPicksExpanded = true
    @State private var isMyBooksExpanded = true

    private var isMyBooksEmpty: Bool {
        readerContentListViewModel.hasLoadedBefore && readerContentListViewModel.filteredContents.isEmpty
    }

    @ViewBuilder
    private var addEpubButton: some View {
        Button {
            bookLibraryModalsModel.isImportingBookFile.toggle()
        } label: {
            Label("Add \(viewModel.mediaFileTypeTitle)", systemImage: "plus.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
        .fontWeight(.semibold)
    }

    @ViewBuilder
    private var myBooksHeader: some View {
        if showsInlineAddButton {
            HStack(alignment: .firstTextBaseline) {
                Text("My \(viewModel.mediaTypeTitle)")
                Spacer()
                if !isMyBooksEmpty {
                    addEpubButton
                }
            }
        } else {
            Text("My \(viewModel.mediaTypeTitle)")
        }
    }

    @ViewBuilder
    private var myBooksSection: some View {
        if isMyBooksEmpty {
            EmptyStateBoxView(
                title: Text("Discover and add books"),
                text: Text("Find books to add in the Editor's Picks section. Add your own books as long as you have the EPUB editions."),
                systemImageName: "books.vertical"
            ) {
                addEpubButton
            }
            .listRowSeparatorIfAvailable(.hidden)
        } else {
            ReaderContentListItems(
                viewModel: readerContentListViewModel,
                entrySelection: $entrySelection,
                includeSource: false,
                alwaysShowThumbnails: true,
                showSeparators: false,
                useCardBackground: false,
                clearRowBackground: true
            )
            .modifier {
#if os(iOS)
                if #available(iOS 16, *) {
                    $0.listRowSpacing(15)
                } else {
                    $0
                }
#else
                $0
#endif
            }
        }
    }

    @ViewBuilder
    var list: some View {
        List(selection: $entrySelection) {
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
        .task { @MainActor in
            await viewModel.fetchAllData()
        }
        .refreshable {
            await viewModel.fetchAllData()
        }
        .task { @MainActor in
            let fileFilter = viewModel.fileFilter
            if let files = readerFileManager.files(ofTypes: viewModel.fileTypes) {
                try? await readerContentListViewModel.load(
                    contents: files,
                    sortOrder: .createdAt,
                    contentFilter: { contentFile in
                        guard let fileFilter else { return true }
                        return try fileFilter(contentFile)
                    }
                )
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
            viewModel.hasLocalFiles = !filteredFileIDs.isEmpty
            guard let loadedFiles = viewModel.loadedFiles else { return }
            Task { @RealmBackgroundActor in
                guard !filteredFileIDs.isEmpty, let realmConfiguration = await readerContentListViewModel.realmConfiguration else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await loadedFiles(filteredFileIDs.compactMap { realm.object(ofType: ContentFile.self, forPrimaryKey: $0) })
            }
        }
    }

    public var body: some View {
        list
    }
}

@MainActor
public class BookLibraryViewModel: ObservableObject {
    nonisolated public static let defaultOPDSURL = URL(string: "https://reader.manabi.io/static/reader/books/opds/index.xml")!

    public let mediaTypeTitle: String
    public let mediaFileTypeTitle: String
    let opdsURL: URL
    let fileTypes: [UTType]
    let fileFilter: ((ContentFile) throws -> Bool)?
    let loadedFiles: (@RealmBackgroundActor ([ContentFile]) async throws -> Void)?

    public init(
        mediaTypeTitle: String = "Books",
        mediaFileTypeTitle: String = "EPUB",
        opdsURL: URL = BookLibraryViewModel.defaultOPDSURL,
        fileTypes: [UTType] = [.epub, .epubZip],
        fileFilter: ((ContentFile) throws -> Bool)? = nil,
        loadedFiles: (@RealmBackgroundActor ([ContentFile]) async throws -> Void)? = nil,
        onNavigateToReader: (() -> Void)? = nil
    ) {
        self.mediaTypeTitle = mediaTypeTitle
        self.mediaFileTypeTitle = mediaFileTypeTitle
        self.opdsURL = opdsURL
        self.fileTypes = fileTypes
        self.fileFilter = fileFilter
        self.loadedFiles = loadedFiles
        self.onNavigateToReader = onNavigateToReader
    }

    @Published var editorsPicks: [Publication] = []
    @Published var errorMessage: String?
    @Published public var hasLocalFiles = false
    @Published public var onNavigateToReader: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    func fetchAllData() async {
        await Self.refreshDownloadedEditorsPicks(readerFileManager: ReaderFileManager.shared)
        fetchEditorsPicks()
    }

    func fetchEditorsPicks() {
        Task {
            let (publications, errorMessage) = await Self.fetchPublications(from: opdsURL)
            await MainActor.run {
                self.editorsPicks = publications
                self.errorMessage = errorMessage
            }
        }
    }

    @MainActor
    public static func refreshDownloadedEditorsPicks(readerFileManager: ReaderFileManager = .shared) async {
        let (publications, _) = await Self.fetchPublications(from: Self.defaultOPDSURL)
        guard !publications.isEmpty else { return }

        var downloads = Set<Downloadable>()
        for publication in publications {
            guard
                let downloadURL = publication.downloadURL,
                let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title),
                await downloadable.existsLocally()
            else { continue }
            downloads.insert(downloadable)
            _ = try? await readerFileManager.importFile(
                fileURL: downloadable.localDestination,
                fromDownloadURL: downloadable.url
            )
        }
        if !downloads.isEmpty {
            await DownloadController.shared.ensureDownloaded(downloads)
        }
    }

    static func fetchPublications(from url: URL) async -> ([Publication], String?) {
        await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: url) { parseData, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(returning: ([], "Failed to fetch data: \(error.localizedDescription)"))
                        return
                    }

                    if let publications = parseData?.feed?.publications, !publications.isEmpty {
                        let mapped = publications.map { publication -> Publication in
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
                        continuation.resume(returning: (mapped, nil))
                        return
                    }

                    if let navigationLinks = parseData?.feed?.navigation,
                       let allBooksLink = navigationLinks.first(where: { $0.title?.hasPrefix("All Books") == true }) {
                        guard let allBooksURL = allBooksLink.url(relativeTo: url.domainURL) ?? URL(string: allBooksLink.href) else {
                            continuation.resume(returning: ([], "Invalid 'All Books' URL"))
                            return
                        }
                        Task {
                            continuation.resume(returning: await Self.fetchPublications(from: allBooksURL))
                        }
                        return
                    }

                    continuation.resume(returning: ([], "No publications or navigable links found"))
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

        let importedURL: URL?
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
            onNavigateToReader?()
        }.value
    }

    @MainActor
    public static func openDownloaded(
        publication: Publication,
        readerFileManager: ReaderFileManager = .shared,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel,
        onNavigateToReader: (() -> Void)? = nil
    ) async throws {
        guard
            let downloadURL = publication.downloadURL,
            let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title),
            await downloadable.existsLocally(),
            let importedURL = try await readerFileManager.readerFileURL(for: downloadable)
        else { return }

        guard let content = try await ReaderContentLoader.load(url: importedURL, persist: true, countsAsHistoryVisit: true) else { return }
        if content.url.matchesReaderURL(readerContent.pageURL) { return }
        try await navigator.load(
            content: content,
            readerFileManager: readerFileManager,
            readerModeViewModel: readerModeViewModel
        )
        onNavigateToReader?()
    }
}

public struct Publication: Identifiable, Hashable {
    public let id = UUID()
    public var title: String
    public var author: String?
    public var publicationDate: Date?
    public var coverURL: URL?
    public var downloadURL: URL?
    public var summary: String?
}
