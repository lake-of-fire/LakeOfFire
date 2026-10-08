import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
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
    @AppStorage("errorMessage") private var errorMessage = ""

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
                                        if let message = ReaderFileImportPresentation.missingResult(for: url) {
                                            errorMessage = message
                                        }
                                        print("Couldn't import \(url.absoluteString)")
                                        return
                                    }
                                } catch {
                                    if let message = ReaderFileImportPresentation.failure(error, importing: url) {
                                        errorMessage = message
                                    }
                                    print("Couldn't import \(url.absoluteString): \(error)")
                                    return
                                }
                            case .failure(let error):
                                if let message = ReaderFileImportPresentation.failure(error) {
                                    errorMessage = message
                                }
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
        Group {
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
                        selectionOwner: viewModel,
                        onSelected: { wasAlreadyDownloaded, selection in
                            guard wasAlreadyDownloaded else { return }
                            do {
                                try await viewModel.open(
                                    publication: publication,
                                    selection: selection,
                                    readerFileManager: ReaderFileManager.shared,
                                    readerPageURL: readerContent.pageURL,
                                    navigator: navigator,
                                    readerModeViewModel: readerModeViewModel
                                )
                            } catch {
                                if viewModel.isCurrentOpenSelection(selection) {
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
        .onDisappear {
            viewModel.cancelOpenSelection()
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
        Group {
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
        .accessibilityIdentifier("BookLibrary.MyBooks.Header")
    }

    private var editorsPicksHeader: some View {
        Text("Editor's Picks")
            .accessibilityIdentifier("BookLibrary.EditorsPicks.Header")
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
            sortOrder: .createdAt,
            contentFilter: { contentFile in
                guard let fileFilter else { return true }
                return try fileFilter(contentFile)
            }
        )
    }
}

@MainActor
public class BookLibraryViewModel: ObservableObject {
    struct OpenSelection: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    struct OpenNavigationClaim {
        let isCurrent: @MainActor () -> Bool
    }

    struct OpenStageOperations {
        let resolveDownloadable: @MainActor () async throws -> Bool
        let existsLocally: @MainActor () async -> Bool
        let importContent: @MainActor (Bool) async throws -> Bool
        let loadContent: @MainActor () async throws -> Bool
        let navigate: @MainActor (OpenNavigationClaim) async throws -> Void
        let publishNavigation: @MainActor () -> Void
    }
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

    var publicationFetcher:
        @MainActor (URL) async -> ([Publication], String?) = {
            await BookLibraryViewModel.fetchPublications(from: $0)
        }

    private var editorsPicksFetchGeneration: UInt64 = 0
    private var editorsPicksFetchTask: Task<Void, Never>?
    private var openSelectionGeneration: UInt64 = 0
    private var openSelectionTask: Task<Void, Never>?

    @discardableResult
    func startOpenSelection(
        _ operation: @escaping @MainActor (OpenSelection) async -> Void
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        openSelectionTask?.cancel()
        openSelectionGeneration &+= 1
        let selection = OpenSelection(generation: openSelectionGeneration)
        let task = Task { @MainActor [weak self] in
            guard let self, self.isCurrentOpenSelection(selection) else {
                return
            }
            await operation(selection)
            if self.isCurrentOpenSelection(selection) {
                self.openSelectionTask = nil
            }
        }
        openSelectionTask = task
        return task
    }

    func isCurrentOpenSelection(_ selection: OpenSelection) -> Bool {
        !Task.isCancelled && selection.generation == openSelectionGeneration
    }

    func cancelOpenSelection() {
        openSelectionGeneration &+= 1
        openSelectionTask?.cancel()
        openSelectionTask = nil
    }

    func fetchAllData() async {
        // A cancelled entrant must not revoke a healthy current producer.
        guard !Task.isCancelled else { return }
        let task = startEditorsPicksFetch()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func fetchEditorsPicks() -> Task<Void, Never> {
        startEditorsPicksFetch()
    }

    @discardableResult
    private func startEditorsPicksFetch() -> Task<Void, Never> {
        editorsPicksFetchTask?.cancel()
        editorsPicksFetchGeneration &+= 1
        let generation = editorsPicksFetchGeneration
        let fetcher = publicationFetcher
        let url = opdsURL

        let task = Task { @MainActor [weak self] in
            defer {
                if self?.editorsPicksFetchGeneration == generation {
                    self?.editorsPicksFetchTask = nil
                }
            }
            // Retry can be replaced or its owner released before this task starts.
            guard !Task.isCancelled,
                  self?.editorsPicksFetchGeneration == generation else { return }
            let (publications, errorMessage) = await fetcher(url)
            guard let self,
                  !Task.isCancelled,
                  self.editorsPicksFetchGeneration == generation
            else {
                return
            }

            self.editorsPicks = publications
            self.errorMessage = errorMessage.map { _ in
                "\(self.mediaTypeTitle) editor's picks are unavailable. Pull to refresh or try again later."
            }
        }
        editorsPicksFetchTask = task
        return task
    }

    @MainActor
    public static func refreshDownloadedEditorsPicks(readerFileManager: ReaderFileManager = .shared) async {
        let (publications, _) = await Self.fetchPublications(from: Self.defaultOPDSURL)
        await refreshDownloadedEditorsPicks(publications: publications, readerFileManager: readerFileManager)
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
                let downloadable = try? await readerFileManager.downloadable(url: downloadURL, name: publication.title)
            else {
                continue
            }
            let existsLocally = await downloadable.existsLocally()
            guard existsLocally else { continue }
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

    @MainActor
    func open(
        publication: Publication,
        selection: OpenSelection,
        readerFileManager: ReaderFileManager = .shared,
        readerPageURL: URL,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel
    ) async throws {
        var downloadable: Downloadable?
        var importedURL: URL?
        var content: (any ReaderContentProtocol)?
        let stages = OpenStageOperations(
            resolveDownloadable: {
                guard let downloadURL = publication.downloadURL else {
                    return false
                }
                downloadable = try? await readerFileManager.downloadable(
                    url: downloadURL,
                    name: publication.title
                )
                return downloadable != nil
            },
            existsLocally: {
                await downloadable?.existsLocally() == true
            },
            importContent: { existsLocally in
                guard let downloadable else { return false }
                if existsLocally {
                    importedURL = try await readerFileManager.ensureImported(
                        downloadable: downloadable
                    )
                } else {
                    importedURL = try await readerFileManager.importFile(
                        fileURL: downloadable.localDestination,
                        fromDownloadURL: downloadable.url
                    )
                    if importedURL == nil {
                        print("Couldn't import \(publication.title) file URL")
                    }
                }
                return importedURL != nil
            },
            loadContent: {
                guard let importedURL else { return false }
                content = try await ReaderContentLoader.load(
                    url: importedURL,
                    persist: true,
                    countsAsHistoryVisit: true,
                    source: "BookLibraryView.openOrDownloadPublication"
                )
                return content?.url.matchesReaderURL(readerPageURL) == false
            },
            navigate: { claim in
                guard let content else { return }
                try await navigator.load(
                    content: content,
                    readerFileManager: readerFileManager,
                    readerModeViewModel: readerModeViewModel,
                    shouldLoad: claim.isCurrent
                )
            },
            publishNavigation: { [weak self] in
                self?.onNavigateToReader?()
            }
        )
        try await Self.runOpenStages(
            stages: stages,
            shouldContinue: { [weak self] in
                self?.isCurrentOpenSelection(selection) == true
            }
        )
    }

    @MainActor
    func open(
        selection: OpenSelection,
        stages: OpenStageOperations
    ) async throws {
        try await Self.runOpenStages(
            stages: stages,
            shouldContinue: { [weak self] in
                self?.isCurrentOpenSelection(selection) == true
            }
        )
    }

    @MainActor
    private static func runOpenStages(
        stages: OpenStageOperations,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws {
        guard shouldContinue() else { return }
        guard try await stages.resolveDownloadable() else { return }
        guard shouldContinue() else { return }

        let existsLocally = await stages.existsLocally()
        guard shouldContinue() else { return }
        guard try await stages.importContent(existsLocally) else { return }
        guard shouldContinue() else { return }
        guard try await stages.loadContent() else { return }
        guard shouldContinue() else { return }

        try await stages.navigate(
            OpenNavigationClaim(isCurrent: shouldContinue)
        )
        guard shouldContinue() else { return }
        stages.publishNavigation()
    }

    @MainActor
    static func openDownloaded(
        stages: OpenStageOperations,
        shouldOpen: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        try await runOpenStages(
            stages: stages,
            shouldContinue: {
                !Task.isCancelled && shouldOpen()
            }
        )
    }

    @MainActor
    public static func openDownloaded(
        publication: Publication,
        readerFileManager: ReaderFileManager = .shared,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel,
        shouldOpen: @escaping @MainActor () -> Bool = { true },
        onNavigateToReader: (() -> Void)? = nil
    ) async throws {
        var downloadable: Downloadable?
        var importedURL: URL?
        var content: (any ReaderContentProtocol)?
        let stages = OpenStageOperations(
            resolveDownloadable: {
                guard let downloadURL = publication.downloadURL else {
                    return false
                }
                downloadable = try? await readerFileManager.downloadable(
                    url: downloadURL,
                    name: publication.title
                )
                return downloadable != nil
            },
            existsLocally: {
                await downloadable?.existsLocally() == true
            },
            importContent: { existsLocally in
                guard existsLocally, let downloadable else { return false }
                importedURL = try await readerFileManager.ensureImported(
                    downloadable: downloadable
                )
                return importedURL != nil
            },
            loadContent: {
                guard let importedURL else { return false }
                content = try await ReaderContentLoader.load(
                    url: importedURL,
                    persist: true,
                    countsAsHistoryVisit: true,
                    source: "BookLibraryView.openDownloaded"
                )
                return content?.url.matchesReaderURL(
                    readerContent.pageURL
                ) == false
            },
            navigate: { claim in
                guard let content else { return }
                try await navigator.load(
                    content: content,
                    readerFileManager: readerFileManager,
                    readerModeViewModel: readerModeViewModel,
                    shouldLoad: claim.isCurrent
                )
            },
            publishNavigation: { onNavigateToReader?() }
        )
        try await openDownloaded(stages: stages, shouldOpen: shouldOpen)
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
    public var hasContentAudio = false
}
