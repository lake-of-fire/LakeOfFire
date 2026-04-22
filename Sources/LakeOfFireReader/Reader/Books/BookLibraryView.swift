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
import LakeOfFireAdblock
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
                // Weird hack because stacking fileImporter breaks all of them
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
        modifier(
            BookLibrarySheetsModifier(
                isActive: isActive,
                bookLibraryModalsModel: bookLibraryModalsModel
            )
        )
    }
}

fileprivate struct EditorsPicksView: View {
    @ObservedObject var viewModel: BookLibraryViewModel
    
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
        if viewModel.editorsPicks.isEmpty {
            EmptyView()
        } else {
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
    private let showsInlineAddButton: Bool

    public init(viewModel: BookLibraryViewModel, showsInlineAddButton: Bool = true) {
        self.viewModel = viewModel
        self.showsInlineAddButton = showsInlineAddButton
    }
    
    @Environment(\.contentSelection) private var contentSelection
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    @StateObject private var readerContentListViewModel = ReaderContentListViewModel<Bookmark>()
    @AppStorage("BookLibraryView.editorsPicks.isExpanded") private var isEditorsPicksExpanded = true
    @State private var isMyBooksExpanded = true

    private var isMyBooksEmpty: Bool {
        readerContentListViewModel.hasLoadedBefore
        && readerContentListViewModel.filteredContents.isEmpty
    }

    @MainActor
    private func reloadMyBooks() async {
        let nativeFiles = (readerFileManager.files(ofTypes: viewModel.fileTypes) ?? []).filter { contentFile in
            guard let fileFilter = viewModel.fileFilter else { return true }
            return (try? fileFilter(contentFile)) ?? false
        }
        debugPrint(
            "# APR21b",
            "source=BookLibraryView.reloadMyBooks.begin",
            "fileTypes=\(viewModel.fileTypes.map(\.identifier).joined(separator: ","))",
            "nativeFiles=\(nativeFiles.count)"
        )

        guard let realm = try? await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration, actor: MainActor.shared) else {
            debugPrint(
                "# APR21b",
                "source=BookLibraryView.reloadMyBooks.realmUnavailable",
                "nativeFiles=\(nativeFiles.count)"
            )
            try? await readerContentListViewModel.load(contents: nativeFiles.map { $0 as Bookmark }, sortOrder: .createdAt)
            return
        }

        let importedExternalBooks = Array(
            realm.objects(Bookmark.self)
                .where { !$0.isDeleted }
        ).filter { bookmark in
            bookmark.url.isReaderBookURL && !bookmark.url.isEBookURL
        }

        var combinedBooks = [Bookmark]()
        combinedBooks.reserveCapacity(nativeFiles.count + importedExternalBooks.count)
        combinedBooks.append(contentsOf: nativeFiles.map { $0 as Bookmark })
        combinedBooks.append(contentsOf: importedExternalBooks)

        let deduplicatedBooks = Dictionary(grouping: combinedBooks, by: \.compoundKey)
            .values
            .compactMap { $0.max(by: { $0.modifiedAt < $1.modifiedAt }) }
            .sorted(using: [KeyPathComparator(\.createdAt, order: .reverse)])
        debugPrint(
            "# APR21b",
            "source=BookLibraryView.reloadMyBooks.result",
            "nativeFiles=\(nativeFiles.count)",
            "importedExternalBooks=\(importedExternalBooks.count)",
            "combinedBooks=\(combinedBooks.count)",
            "deduplicatedBooks=\(deduplicatedBooks.count)"
        )
        viewModel.hasLocalFiles = !deduplicatedBooks.isEmpty

        try? await readerContentListViewModel.load(contents: deduplicatedBooks)
    }

    @ViewBuilder
    private var addEpubButton: some View {
        Button {
            bookLibraryModalsModel.isImportingBookFile.toggle()
        } label: {
            Text("Add \(viewModel.mediaFileTypeTitle)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
        .fontWeight(.semibold)
    }

    @ViewBuilder
    private var inlineAddEpubButton: some View {
        addEpubButton
            .tint(.secondary)
    }
    
    @ViewBuilder private var myBooksHeader: some View {
        if showsInlineAddButton {
            HStack(alignment: .firstTextBaseline) {
                Text("My \(viewModel.mediaTypeTitle)")
                Spacer()
                if !isMyBooksEmpty {
                    inlineAddEpubButton
                }
            }
        } else {
            Text("My \(viewModel.mediaTypeTitle)")
        }
    }
    
    @ViewBuilder private var myBooksSection: some View {
        let filteredCount = readerContentListViewModel.filteredContents.count
        let hasLoadedBefore = readerContentListViewModel.hasLoadedBefore
        let localFiles = viewModel.hasLocalFiles
        let empty = isMyBooksEmpty
        let key = [String(filteredCount), String(hasLoadedBefore), String(localFiles), String(empty)].joined(separator: "|")
        Group {
            if isMyBooksEmpty {
                EmptyStateBoxView(
                    title: Text("Discover and add books"),
                    text: Text("Find books to add in the Editor's Picks section, import your own EPUB editions, or link books from Ttsu Reader in User Data settings."),
                    systemImageName: "books.vertical"
                ) {
                    addEpubButton
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
        .task(id: key) {
            debugPrint(
                "# APR21b",
                "source=BookLibraryView.myBooksSection",
                "filteredContents=\(filteredCount)",
                "hasLoadedBefore=\(hasLoadedBefore)",
                "hasLocalFiles=\(localFiles)",
                "isMyBooksEmpty=\(empty)"
            )
        }
    }

    @ViewBuilder var list: some View {
        List(selection: contentSelection) {
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
            await reloadMyBooks()
        }
        .task { @MainActor in
            await reloadMyBooks()
        }
        .task(
            id: [
                String(readerContentListViewModel.hasLoadedBefore),
                String(readerContentListViewModel.filteredContents.count),
                String(readerContentListViewModel.filteredContentIDs.count),
                String(viewModel.hasLocalFiles)
            ].joined(separator: "|")
        ) {
            debugPrint(
                "# APR21b",
                "source=BookLibraryView.renderState",
                "hasLoadedBefore=\(readerContentListViewModel.hasLoadedBefore)",
                "filteredContents=\(readerContentListViewModel.filteredContents.count)",
                "filteredContentIDs=\(readerContentListViewModel.filteredContentIDs.count)",
                "hasLocalFiles=\(viewModel.hasLocalFiles)",
                "isMyBooksEmpty=\(isMyBooksEmpty)"
            )
        }
        .onChange(of: readerFileManager.files(ofTypes: viewModel.fileTypes)) { ebookFiles in
            Task { @MainActor in
                if ebookFiles != nil {
                    await reloadMyBooks()
                }
            }
        }
        .onChange(of: readerContentListViewModel.filteredContentIDs) { filteredFileIDs in
            let hasAnyFilteredBooks = !readerContentListViewModel.filteredContents.isEmpty
            viewModel.hasLocalFiles = hasAnyFilteredBooks
            debugPrint(
                "# APR21b",
                "source=BookLibraryView.filteredContentIDsChanged",
                "filteredFileIDs=\(filteredFileIDs.count)",
                "filteredContents=\(readerContentListViewModel.filteredContents.count)",
                "hasLocalFiles=\(viewModel.hasLocalFiles)"
            )
            let nativeFilteredFiles = readerContentListViewModel.filteredContents.compactMap { $0 as? ContentFile }
            guard let loadedFiles = viewModel.loadedFiles else { return }
            Task { @RealmBackgroundActor in
                guard !nativeFilteredFiles.isEmpty, let realmConfiguration = await readerContentListViewModel.realmConfiguration else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await loadedFiles(nativeFilteredFiles.compactMap { realm.object(ofType: ContentFile.self, forPrimaryKey: $0.compoundKey) })
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
    let fileFilter: (@Sendable (ContentFile) throws -> Bool)?
    /// Loaded in RealmBackgroundActor
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
    /// Hook used by host apps to run navigation side effects (e.g., clearing tab selection) after jumping into the reader.
    @Published public var onNavigateToReader: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    
    func fetchAllData() async {
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
        debugPrint(
            "# APR21b",
            "source=BookLibraryViewModel.refreshDownloadedEditorsPicks.begin",
            "publications=\(publications.count)"
        )
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
        debugPrint(
            "# APR21b",
            "source=BookLibraryViewModel.refreshDownloadedEditorsPicks.downloads",
            "downloads=\(downloads.count)"
        )
        if !downloads.isEmpty {
            await DownloadController.shared.ensureDownloaded(downloads)
            try? await readerFileManager.refreshAllFilesMetadata()
            let localFilesAfterRefresh = readerFileManager.files(ofTypes: [.epub, .epubZip]) ?? []
            debugPrint(
                "# APR21b",
                "source=BookLibraryViewModel.refreshDownloadedEditorsPicks.refreshed",
                "downloads=\(downloads.count)",
                "localFilesAfterRefresh=\(localFilesAfterRefresh.count)"
            )
        }

        await updateMediaLinks(for: publications, readerFileManager: readerFileManager)
    }

    @MainActor
    static func updateMediaLinks(for publications: [Publication], readerFileManager: ReaderFileManager = .shared) async {
        let localFiles = readerFileManager.files(ofTypes: [.epub, .epubZip]) ?? []
        debugPrint(
            "# APR21b",
            "source=BookLibraryViewModel.updateMediaLinks.begin",
            "publications=\(publications.count)",
            "localFiles=\(localFiles.count)"
        )
        for publication in publications {
            guard publication.voiceAudioURL != nil || publication.audioSubtitlesURL != nil else { continue }
            guard
                let downloadURL = publication.downloadURL,
                let content = localFiles.first(where: { $0.url == downloadURL || $0.sourceDownloadURL == downloadURL })
            else { continue }
            let voiceAudioURL = publication.voiceAudioURL
            let audioSubtitlesURL = publication.audioSubtitlesURL
            let subtitleRole = audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil
            try? await ReaderContentLoader.updateContent(url: content.url) { object in
                var changed = false
                if object.voiceAudioURL != voiceAudioURL {
                    object.voiceAudioURL = voiceAudioURL
                    changed = true
                }
                if object.audioSubtitlesURL != audioSubtitlesURL {
                    object.audioSubtitlesURL = audioSubtitlesURL
                    changed = true
                }
                if object.audioSubtitlesRoleRawValue != subtitleRole {
                    object.audioSubtitlesRoleRawValue = subtitleRole
                    changed = true
                }
                return changed
            }
        }
    }
    
    static func fetchPublications(from url: URL) async -> ([Publication], String?) {
        await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: url) { parseData, error in
                Task { @MainActor in
                    if let error = error {
                        continuation.resume(returning: ([], "Failed to fetch data: \(error.localizedDescription)"))
                        return
                    }
                    
                    if let publications = parseData?.feed?.publications, !publications.isEmpty {
                        let mapped = publications.map { publication -> Publication in
                            let coverLink = publication.images.first(withRel: .cover) ?? publication.images.first(withRel: .opdsImage) ?? publication.images.first(withRel: .opdsImageThumbnail)
                            let acquisitionLink = publication.links.first(withRel: .opdsAcquisition)
                            let audioLink = publication.links.first { link in
                                guard let type = link.type else { return false }
                                return type.hasPrefix("audio/") || type.contains("audio")
                            }
                            let subtitleLink = publication.links.first { link in
                                guard let type = link.type else { return false }
                                return type.contains("vtt") || type == "text/vtt"
                            }
                            let summary = publication.metadata.description ?? publication.metadata.subtitle
                            // Show the OPDS published date only; if missing, omit the date entirely.
                            let publishedDate = publication.metadata.published
                            return Publication(
                                title: publication.metadata.title,
                                author: publication.metadata.authors.map { $0.name } .joined(separator: ", "),
                                publicationDate: publishedDate,
                                coverURL: coverLink?.url(relativeTo: url.domainURL),
                                downloadURL: acquisitionLink?.url(relativeTo: url.domainURL),
                                summary: summary,
                                voiceAudioURL: audioLink?.url(relativeTo: url.domainURL),
                                audioSubtitlesURL: subtitleLink?.url(relativeTo: url.domainURL)
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
                            let result = await Self.fetchPublications(from: allBooksURL)
                            continuation.resume(returning: result)
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
        guard let content = try await ReaderContentLoader.load(url: toLoad, persist: true, countsAsHistoryVisit: true), !content.url.matchesReaderURL(readerPageURL) else { return }
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

public struct Publication: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var author: String?
    public var publicationDate: Date?
    public var coverURL: URL?
    public var downloadURL: URL?
    public var summary: String?
    public var voiceAudioURL: URL?
    public var audioSubtitlesURL: URL?

    public var hasContentAudio: Bool {
        voiceAudioURL != nil || audioSubtitlesURL != nil
    }
}
