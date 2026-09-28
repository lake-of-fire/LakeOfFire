import SwiftUI
import SwiftUIWebView
import LakeOfFireOPDS
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
import Combine
import UniformTypeIdentifiers
import LakeKit
import LakeOfFireCore
import LakeOfFireContent
import LakeOfFireContentUI

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
                    .readerContentFileImporter(
                        isPresented: $bookLibraryModalsModel.isImportingBookFile.gatedBy(isActive)
                    )
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
                Text(errorMessage)
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
                            do {
                                try await viewModel.open(
                                    publication: publication,
                                    readerFileManager: ReaderFileManager.shared,
                                    readerPageURL: readerContent.pageURL,
                                    navigator: navigator,
                                    readerModeViewModel: readerModeViewModel
                                )
                            } catch {
                                viewModel.errorMessage = ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
                            }
                        }
                    },
                    onNavigateToReader: viewModel.onNavigateToReader
                )
                .accessibilityIdentifier("BookLibrary.EditorsPick.Row.\(publication.title)")
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

    @Environment(\.contentSelection) private var contentSelection

    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager

    @StateObject private var readerContentListViewModel = ReaderContentListViewModel<ContentFile>()
    @AppStorage("BookLibraryView.editorsPicks.isExpanded") private var isEditorsPicksExpanded = true
    @State private var isMyBooksExpanded = true

    private var isMyBooksEmpty: Bool {
        readerContentListViewModel.hasLoadedBefore && readerContentListViewModel.filteredContents.isEmpty
    }

    private var mediaTypeTitleLowercased: String {
        viewModel.mediaTypeTitle.lowercased()
    }

    private var addFileButtonTitle: String {
        if viewModel.mediaTypeTitle == "Books" {
            return "Add \(viewModel.mediaFileTypeTitle) Ebook"
        }
        return "Add \(viewModel.mediaFileTypeTitle)"
    }

    private var editorsPicksHeader: some View {
        Text("Editor's Picks")
            .accessibilityIdentifier("BookLibrary.EditorsPicks.Header")
    }

    @ViewBuilder
    private var addFileButton: some View {
        Button {
            bookLibraryModalsModel.isImportingBookFile.toggle()
        } label: {
            Text(addFileButtonTitle)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
        .fontWeight(.semibold)
    }

    @ViewBuilder
    private var inlineAddFileButton: some View {
        addFileButton
            .tint(.secondary)
    }

    @ViewBuilder
    private var myBooksHeader: some View {
        if showsInlineAddButton {
            HStack(alignment: .firstTextBaseline) {
                Text("My \(viewModel.mediaTypeTitle)")
                Spacer()
                if !isMyBooksEmpty {
                    inlineAddFileButton
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
                title: Text("Discover and add \(mediaTypeTitleLowercased)"),
                text: Text("Find \(mediaTypeTitleLowercased) to add in the Editor's Picks section. Add your own \(mediaTypeTitleLowercased) as long as you have the \(viewModel.mediaFileTypeTitle) files."),
                systemImageName: "books.vertical"
            ) {
                addFileButton
            }
            .listRowSeparatorIfAvailable(.hidden)
        } else {
            ReaderContentListItems(
                viewModel: readerContentListViewModel,
                entrySelection: contentSelection,
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
        List(selection: contentSelection) {
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
                Section(isExpanded: $isEditorsPicksExpanded) {
                    EditorsPicksView(viewModel: viewModel)
                } header: {
                    editorsPicksHeader
                }
            } else {
                Section {
                    EditorsPicksView(viewModel: viewModel)
                } header: {
                    editorsPicksHeader
                }
            }
        }
#if os(iOS)
        .listStyle(.sidebar)
#endif
        .accessibilityIdentifier("BookLibrary.Root")
        .scrollContentBackgroundIfAvailable(.hidden)
        .task { @MainActor in
            await viewModel.fetchAllData()
        }
        .refreshable {
            await viewModel.fetchAllData()
        }
        .task { @MainActor in
            await loadMyBooks(readerFileManager.files(ofTypes: viewModel.fileTypes) ?? [])
        }
        .onChange(of: readerFileManager.files(ofTypes: viewModel.fileTypes)) { ebookFiles in
            Task { @MainActor in
                guard let ebookFiles else { return }
                await loadMyBooks(ebookFiles)
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

    @MainActor
    private func loadMyBooks(_ files: [ContentFile]) async {
        let fileFilter = viewModel.fileFilter
        try? await readerContentListViewModel.load(
            contents: files,
            contentFilter: { _, contentFile in
                guard let fileFilter else { return true }
                return try fileFilter(contentFile)
            },
            sortOrder: .createdAt
        )
    }
}

@MainActor
public class BookLibraryViewModel: ObservableObject {
    nonisolated public static let defaultOPDSURL = URL(string: "https://reader.manabi.io/static/reader/books/opds/index.xml")!

    public let mediaTypeTitle: String
    public let mediaFileTypeTitle: String
    let opdsURL: URL
    let fileTypes: [UTType]
    let fileFilter: (@Sendable (ContentFile) throws -> Bool)?
    let loadedFiles: (@RealmBackgroundActor ([ContentFile]) async throws -> Void)?

    public init(
        mediaTypeTitle: String = "Books",
        mediaFileTypeTitle: String = "EPUB",
        opdsURL: URL = BookLibraryViewModel.defaultOPDSURL,
        fileTypes: [UTType] = [.epub, .epubZip],
        fileFilter: (@Sendable (ContentFile) throws -> Bool)? = nil,
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

    var publicationFetcher: @MainActor (URL) async -> ([Publication], String?) = {
        await BookLibraryViewModel.fetchPublications(from: $0)
    }
    private let editorsPicksRefresh = BookCatalogRefresh()

    func fetchAllData() async {
        let fetcher = publicationFetcher
        let url = opdsURL
        await editorsPicksRefresh.load(
            fetch: { await fetcher(url) },
            publish: { [weak self] in self?.publishEditorsPicks($0, error: $1) }
        )
    }

    @discardableResult
    func fetchEditorsPicks() -> Task<Void, Never>? {
        let fetcher = publicationFetcher
        let url = opdsURL
        return editorsPicksRefresh.start(
            fetch: { await fetcher(url) },
            publish: { [weak self] in self?.publishEditorsPicks($0, error: $1) }
        )
    }

    private func publishEditorsPicks(_ publications: [Publication], error: String?) {
        editorsPicks = publications
        errorMessage = error.map { _ in
            "\(mediaTypeTitle) editor's picks are unavailable. Pull to refresh or try again later."
        }
    }

    @MainActor
    public static func refreshDownloadedEditorsPicks(readerFileManager: ReaderFileManager = .shared) async {
        let (publications, _) = await Self.fetchPublications(from: Self.defaultOPDSURL)
        await refreshDownloadedEditorsPicks(
            publications: publications,
            readerFileManager: readerFileManager
        )
    }

    @MainActor
    static func refreshDownloadedEditorsPicks(
        publications: [Publication],
        readerFileManager: ReaderFileManager = .shared
    ) async {
        guard !publications.isEmpty else { return }

        var downloads = Set<Downloadable>()
        for publication in publications {
            guard
                let downloadURL = publication.downloadURL,
                let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title),
                await downloadable.existsLocally()
            else { continue }
            downloads.insert(downloadable)
        }
        if !downloads.isEmpty {
            await DownloadController.shared.ensureDownloaded(downloads)
            for download in downloads {
                _ = try? await readerFileManager.ensureImported(downloadable: download)
            }
        }
    }

    static func fetchPublications(from url: URL) async -> ([Publication], String?) {
        do {
            return (try await BookCatalogLoading.publications(from: url), nil)
        } catch {
            return ([], "Failed to fetch data: \(error.localizedDescription)")
        }
    }

    @MainActor
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
            importedURL = try await readerFileManager.ensureImported(downloadable: downloadable)
        } else {
            guard let importedFileURL = try await readerFileManager.importFile(fileURL: downloadable.localDestination, fromDownloadURL: downloadable.url) else {
                print("Couldn't import \(publication.title) file URL")
                return
            }
            importedURL = importedFileURL
        }

        guard let toLoad = importedURL else { return }
        guard let content = try await ReaderContentLoader.load(
            url: toLoad,
            persist: true,
            countsAsHistoryVisit: true,
            source: "BookLibraryView.openOrDownloadPublication"
        ), !content.url.matchesReaderURL(readerPageURL) else { return }
        try await navigator.load(
            content: content,
            readerFileManager: readerFileManager,
            readerModeViewModel: readerModeViewModel
        )
        onNavigateToReader?()
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
            let importedURL = try await readerFileManager.ensureImported(downloadable: downloadable)
        else { return }

        guard let content = try await ReaderContentLoader.load(
            url: importedURL,
            persist: true,
            countsAsHistoryVisit: true,
            source: "BookLibraryView.openDownloaded"
        ) else { return }
        if content.url.matchesReaderURL(readerContent.pageURL) { return }
        try await navigator.load(
            content: content,
            readerFileManager: readerFileManager,
            readerModeViewModel: readerModeViewModel
        )
        onNavigateToReader?()
    }
}
