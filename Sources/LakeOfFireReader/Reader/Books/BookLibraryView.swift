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
    @Published private(set) var manualBookImportOutcome: ManualBookImportOutcome?
    @Published private(set) var manualBookImportFailure: ManualBookImportFailure?

    private var manualBookImportTask: Task<Void, Never>?
    private var manualBookImportGeneration: UInt64 = 0
    private var manualBookImportHostIdentity: ObjectIdentifier?
    private var manualBookImportManagerIdentity: ObjectIdentifier?
    private var manualBookImportRetry: (() -> Void)?

    public init() { }

    func activateManualBookImportHost(_ host: AnyObject, readerFileManager: ReaderFileManager) {
        let hostIdentity = ObjectIdentifier(host)
        let managerIdentity = ObjectIdentifier(readerFileManager)
        guard manualBookImportHostIdentity != hostIdentity || manualBookImportManagerIdentity != managerIdentity else {
            return
        }
        revokeManualBookImport(clearPresentation: true)
        manualBookImportHostIdentity = hostIdentity
        manualBookImportManagerIdentity = managerIdentity
    }

    func deactivateManualBookImportHost(_ host: AnyObject) {
        guard manualBookImportHostIdentity == ObjectIdentifier(host) else { return }
        revokeManualBookImport(clearPresentation: true)
        manualBookImportHostIdentity = nil
        manualBookImportManagerIdentity = nil
    }

    func handleManualBookFileImporterResult(
        _ result: Result<URL, Error>,
        host: AnyObject,
        readerFileManager: ReaderFileManager,
        importFile: @escaping @MainActor (URL) async throws -> URL?
    ) {
        guard ownsManualBookImportHost(host, readerFileManager: readerFileManager) else { return }
        switch result {
        case .success(let url):
            startManualBookImport(
                url: url,
                host: host,
                readerFileManager: readerFileManager,
                importFile: importFile
            )
        case .failure(let error):
            publishManualBookImportFailure(
                .fileImporterFailed(error.localizedDescription),
                host: host,
                readerFileManager: readerFileManager
            )
        }
    }

    func retryManualBookImport() {
        manualBookImportRetry?()
    }

    func dismissManualBookImportFailure() {
        manualBookImportFailure = nil
        manualBookImportRetry = nil
    }

    func ownsManualBookImportHost(_ host: AnyObject, readerFileManager: ReaderFileManager) -> Bool {
        manualBookImportHostIdentity == ObjectIdentifier(host)
            && manualBookImportManagerIdentity == ObjectIdentifier(readerFileManager)
    }

    var canRetryManualBookImport: Bool {
        manualBookImportRetry != nil
    }

    private func startManualBookImport(
        url: URL,
        host: AnyObject,
        readerFileManager: ReaderFileManager,
        importFile: @escaping @MainActor (URL) async throws -> URL?
    ) {
        let hostIdentity = ObjectIdentifier(host)
        let managerIdentity = ObjectIdentifier(readerFileManager)
        guard manualBookImportHostIdentity == hostIdentity,
              manualBookImportManagerIdentity == managerIdentity
        else { return }
        revokeManualBookImport()
        manualBookImportHostIdentity = hostIdentity
        manualBookImportManagerIdentity = managerIdentity
        let generation = manualBookImportGeneration
        let retry = { [weak self, weak host, weak readerFileManager] in
            guard let self, let host, let readerFileManager else { return }
            self.startManualBookImport(
                url: url,
                host: host,
                readerFileManager: readerFileManager,
                importFile: importFile
            )
        }
        manualBookImportRetry = retry
        manualBookImportTask = Task { @MainActor [weak self] in
            let outcome: ManualBookImportOutcome
            do {
                guard let importedURL = try await importFile(url) else {
                    outcome = .failed(.missingImportResult)
                    self?.finishManualBookImport(
                        outcome,
                        generation: generation,
                        hostIdentity: hostIdentity,
                        managerIdentity: managerIdentity
                    )
                    return
                }
                outcome = .imported(importedURL)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(.importFailed(error.localizedDescription))
            }
            self?.finishManualBookImport(
                outcome,
                generation: generation,
                hostIdentity: hostIdentity,
                managerIdentity: managerIdentity
            )
        }
    }

    private func publishManualBookImportFailure(
        _ failure: ManualBookImportFailure,
        host: AnyObject,
        readerFileManager: ReaderFileManager
    ) {
        guard manualBookImportHostIdentity == ObjectIdentifier(host),
              manualBookImportManagerIdentity == ObjectIdentifier(readerFileManager)
        else { return }
        revokeManualBookImport()
        manualBookImportOutcome = .failed(failure)
        manualBookImportFailure = failure
        manualBookImportRetry = nil
    }

    private func finishManualBookImport(
        _ outcome: ManualBookImportOutcome,
        generation: UInt64,
        hostIdentity: ObjectIdentifier,
        managerIdentity: ObjectIdentifier
    ) {
        guard !Task.isCancelled,
              manualBookImportGeneration == generation,
              manualBookImportHostIdentity == hostIdentity,
              manualBookImportManagerIdentity == managerIdentity
        else { return }
        manualBookImportTask = nil
        manualBookImportOutcome = outcome
        switch outcome {
        case .imported:
            manualBookImportFailure = nil
            manualBookImportRetry = nil
        case .failed(let failure):
            manualBookImportFailure = failure
        case .cancelled, .superseded:
            break
        }
    }

    private func revokeManualBookImport(clearPresentation: Bool = false) {
        manualBookImportTask?.cancel()
        manualBookImportTask = nil
        manualBookImportGeneration &+= 1
        guard clearPresentation else { return }
        manualBookImportOutcome = nil
        manualBookImportFailure = nil
        manualBookImportRetry = nil
    }
}

public enum ManualBookImportFailure: LocalizedError, Sendable, Equatable {
    case fileImporterFailed(String)
    case missingImportResult
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileImporterFailed(let message), .importFailed(let message): return message
        case .missingImportResult: return "The selected book could not be added to your library."
        }
    }
}

public enum ManualBookImportOutcome: Sendable, Equatable {
    case imported(URL)
    case failed(ManualBookImportFailure)
    case cancelled
    case superseded
}

private final class BookLibrarySheetsHost: NSObject, ObservableObject { }

struct BookLibrarySheetsModifier: ViewModifier {
    let isActive: Bool
    @ObservedObject var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager

    @StateObject private var opdsCatalogsViewModel = OPDSCatalogsViewModel()
    @StateObject private var host = BookLibrarySheetsHost()

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
                    .fileImporter(
                        isPresented: $bookLibraryModalsModel.isImportingBookFile.gatedBy(isActive),
                        allowedContentTypes: readerFileManager.readerContentMimeTypes
                    ) { result in
                        guard isActive else { return }
                        bookLibraryModalsModel.handleManualBookFileImporterResult(
                            result,
                            host: host,
                            readerFileManager: readerFileManager
                        ) { url in
                            try await readerFileManager.importFile(fileURL: url, fromDownloadURL: nil)
                        }
                    }
            }
            .onAppear {
                if isActive {
                    bookLibraryModalsModel.activateManualBookImportHost(
                        host,
                        readerFileManager: readerFileManager
                    )
                }
            }
            .onChange(of: isActive) { isActive in
                if isActive {
                    bookLibraryModalsModel.activateManualBookImportHost(
                        host,
                        readerFileManager: readerFileManager
                    )
                } else {
                    bookLibraryModalsModel.deactivateManualBookImportHost(host)
                }
            }
            .onChange(of: ObjectIdentifier(readerFileManager)) { _ in
                if isActive {
                    bookLibraryModalsModel.activateManualBookImportHost(
                        host,
                        readerFileManager: readerFileManager
                    )
                }
            }
            .onDisappear {
                bookLibraryModalsModel.deactivateManualBookImportHost(host)
            }
            .alert(
                "Couldn’t Import Book",
                isPresented: Binding(
                    get: {
                        isActive
                            && bookLibraryModalsModel.ownsManualBookImportHost(
                                host,
                                readerFileManager: readerFileManager
                            )
                            && bookLibraryModalsModel.manualBookImportFailure != nil
                    },
                    set: { if !$0 { bookLibraryModalsModel.dismissManualBookImportFailure() } }
                ),
                presenting: bookLibraryModalsModel.manualBookImportFailure
            ) { _ in
                if bookLibraryModalsModel.canRetryManualBookImport {
                    Button("Retry") { bookLibraryModalsModel.retryManualBookImport() }
                }
                Button("Dismiss", role: .cancel) {
                    bookLibraryModalsModel.dismissManualBookImportFailure()
                }
            } message: { failure in
                Text(failure.localizedDescription)
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
    @EnvironmentObject private var readerFileManager: ReaderFileManager
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
                    commandOwner: viewModel,
                    suppliedReaderFileManager: readerFileManager,
                    readerPageURL: readerContent.pageURL,
                    navigator: navigator,
                    readerModeViewModel: readerModeViewModel
                )
                .accessibilityIdentifier("BookLibrary.EditorsPick.Row.\(publication.title)")
            }
        }
        .onDisappear {
            viewModel.cancelCatalogBookCommands()
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
    @State private var myBooksLoadRevision: UInt = 0

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
        if let loadFailure = readerContentListViewModel.loadFailure {
            ReaderContentListLoadFailureView(
                failure: loadFailure,
                retry: { myBooksLoadRevision &+= 1 }
            )
        }
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
        .task(id: myBooksLoadRevision) { @MainActor in
            await loadMyBooks(readerFileManager.files(ofTypes: viewModel.fileTypes) ?? [])
        }
        .onChange(of: readerFileManager.files(ofTypes: viewModel.fileTypes)) { _ in
            myBooksLoadRevision &+= 1
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
        do {
            try await readerContentListViewModel.load(
                contents: files,
                contentFilter: { _, contentFile in
                    guard let fileFilter else { return true }
                    return try fileFilter(contentFile)
                },
                sortOrder: .createdAt
            )
        } catch is CancellationError {
        } catch {
            // The list view model retains the current failure for presentation and retry.
        }
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
    @Published private(set) var catalogBookOutcomes = [String: CatalogBookCommandOutcome]()
    @Published private(set) var catalogBookErrorMessages = [String: String]()
    @Published public var hasLocalFiles = false
    @Published public var onNavigateToReader: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var catalogBookCommandGenerations = [String: UInt64]()
    private var catalogBookCommandTasks = [String: Task<Void, Never>]()
    private var catalogBookLoadAdmissions = [String: ReaderContentLoadAdmission]()
    private var catalogBookCommandManagerIdentities = [String: ObjectIdentifier]()

    private struct CatalogBookCommandToken: Equatable {
        let publicationID: String
        let generation: UInt64
        let admission: ReaderContentLoadAdmission
        let presentsFailures: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.publicationID == rhs.publicationID && lhs.generation == rhs.generation
        }
    }

    struct CatalogBookCommandClaim {
        fileprivate let isCurrentOperation: @MainActor () -> Bool
        let admission: ReaderContentLoadAdmission

        @MainActor
        func isCurrent() -> Bool {
            isCurrentOperation() && !Task.isCancelled
        }
    }

    func fetchAllData() async {
        fetchEditorsPicks()
    }

    func fetchEditorsPicks() {
        Task {
            let (publications, errorMessage) = await Self.fetchPublications(from: opdsURL)
            await MainActor.run {
                self.editorsPicks = publications
                self.errorMessage = errorMessage.map { _ in
                    "\(mediaTypeTitle) editor's picks are unavailable. Pull to refresh or try again later."
                }
            }
        }
    }

    @MainActor
    public static func refreshDownloadedEditorsPicks(
        readerFileManager: ReaderFileManager = .shared
    ) async -> CatalogBookRefreshOutcome {
        let (publications, _) = await Self.fetchPublications(from: Self.defaultOPDSURL)
        return await refreshDownloadedEditorsPicks(
            publications: publications,
            readerFileManager: readerFileManager
        )
    }

    @MainActor
    static func refreshDownloadedEditorsPicks(
        publications: [Publication],
        readerFileManager: ReaderFileManager
    ) async -> CatalogBookRefreshOutcome {
        var outcomes = [String: CatalogBookCommandOutcome]()
        var localDownloads = [(publication: Publication, downloadable: Downloadable)]()
        for publication in publications {
            guard let downloadURL = publication.downloadURL else {
                outcomes[publication.id] = .failed(.noAcquisition)
                continue
            }
            do {
                guard let downloadable = try await readerFileManager.downloadable(
                    url: downloadURL,
                    name: publication.title
                ) else {
                    outcomes[publication.id] = .failed(.unavailable)
                    continue
                }
                guard await downloadable.existsLocally() else {
                    outcomes[publication.id] = .failed(.notLocal)
                    continue
                }
                localDownloads.append((publication, downloadable))
            } catch {
                outcomes[publication.id] = .failed(.unavailable)
            }
        }
        if !localDownloads.isEmpty {
            await DownloadController.shared.ensureDownloaded(localDownloads.map { $0.downloadable })
        }
        for entry in localDownloads {
            do {
                guard try await entry.downloadable.awaitCompletionOrFailure() else {
                    outcomes[entry.publication.id] = .failed(.downloadFailed("The book download failed."))
                    continue
                }
            } catch {
                outcomes[entry.publication.id] = .failed(.downloadFailed(error.localizedDescription))
                continue
            }
            outcomes[entry.publication.id] = await reconcileDownloadedPublication(
                entry.publication,
                readerFileManager: readerFileManager
            )
        }
        return CatalogBookRefreshOutcome(outcomes: outcomes)
    }

    static func fetchPublications(from url: URL) async -> ([Publication], String?) {
        await withCheckedContinuation { continuation in
            OPDSParser.parseURL(url: url) { parseData, error in
                if let error {
                    continuation.resume(returning: ([], "Failed to fetch data: \(error.localizedDescription)"))
                    return
                }

                if let publications = parseData?.feed?.publications, !publications.isEmpty {
                    let mapped = mapCatalogPublications(publications, catalogURL: url)
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

    /// Gives each presentation row its own stable identity. The acquisition URL remains
    /// deliberately separate: it is the identity ReaderFileManager uses for artifacts.
    struct CatalogPublicationDescriptor: Sendable {
        let identifier: String?
        let title: String
        let author: String?
        let publicationDate: Date?
        let coverURL: URL?
        let downloadURL: URL?
        let summary: String?
        let hasContentAudio: Bool
    }

    nonisolated static func mapCatalogPublications(
        _ publications: [LakeOfFireOPDS.Publication],
        catalogURL: URL
    ) -> [Publication] {
        let descriptors = publications.map { publication in
            let coverLink = publication.images.first(withRel: .cover)
                ?? publication.images.first(withRel: .opdsImage)
                ?? publication.images.first(withRel: .opdsImageThumbnail)
            let acquisitionLink = publication.links.first(withRel: .opdsAcquisition)
            return CatalogPublicationDescriptor(
                identifier: publication.metadata.identifier,
                title: publication.metadata.title,
                author: publication.metadata.authors.map(\.name).joined(separator: ", "),
                publicationDate: publication.metadata.published,
                coverURL: coverLink?.url(relativeTo: catalogURL.domainURL),
                downloadURL: acquisitionLink?.url(relativeTo: catalogURL.domainURL),
                summary: publication.metadata.description ?? publication.metadata.subtitle,
                hasContentAudio: false
            )
        }
        return mapCatalogPublicationDescriptors(descriptors, catalogURL: catalogURL)
    }

    nonisolated static func mapCatalogPublicationDescriptors(
        _ descriptors: [CatalogPublicationDescriptor],
        catalogURL: URL
    ) -> [Publication] {
        var occurrenceCounts = [String: Int]()

        return descriptors.map { descriptor in
            let identifier = descriptor.identifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identityBasis: String
            if let identifier, !identifier.isEmpty {
                identityBasis = "opds-identifier:\(identifier)"
            } else if let downloadURL = descriptor.downloadURL {
                identityBasis = "acquisition:\(downloadURL.absoluteString)"
            } else {
                identityBasis = "metadata:\(catalogRowMetadataIdentity(descriptor))"
            }
            let occurrence = occurrenceCounts[identityBasis, default: 0]
            occurrenceCounts[identityBasis] = occurrence + 1
            let catalogRowID = makeCatalogRowID(
                catalogURL: catalogURL,
                identityBasis: identityBasis,
                occurrence: occurrence
            )
            return Publication(
                title: descriptor.title,
                author: descriptor.author,
                publicationDate: descriptor.publicationDate,
                coverURL: descriptor.coverURL,
                downloadURL: descriptor.downloadURL,
                summary: descriptor.summary,
                hasContentAudio: descriptor.hasContentAudio,
                catalogRowID: catalogRowID
            )
        }
    }

    nonisolated private static func catalogRowMetadataIdentity(
        _ descriptor: CatalogPublicationDescriptor
    ) -> String {
        [
            descriptor.title,
            descriptor.author ?? "",
            descriptor.publicationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    nonisolated private static func makeCatalogRowID(
        catalogURL: URL,
        identityBasis: String,
        occurrence: Int
    ) -> String {
        let components = ["catalog-row", catalogURL.absoluteString, identityBasis, String(occurrence)]
        return components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    func catalogBookErrorMessage(for publication: Publication) -> String? {
        catalogBookErrorMessages[publication.id]
    }

    func isCatalogBookImported(_ publication: Publication) -> Bool {
        guard let outcome = catalogBookOutcomes[publication.id] else { return false }
        return outcome.marksImported
    }

    func isCatalogBookCommandActive(_ publication: Publication) -> Bool {
        catalogBookCommandTasks[publication.id] != nil
    }

    func cancelCatalogBookCommand(for publication: Publication) {
        catalogBookCommandTasks[publication.id]?.cancel()
        catalogBookCommandTasks[publication.id] = nil
        catalogBookLoadAdmissions[publication.id]?.retire()
        catalogBookLoadAdmissions[publication.id] = nil
        catalogBookCommandManagerIdentities[publication.id] = nil
        catalogBookCommandGenerations[publication.id, default: 0] &+= 1
    }

    func startManualCatalogBookCommand(
        publication: Publication,
        readerFileManager: ReaderFileManager,
        readerPageURL: URL,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel
    ) {
        startCatalogBookCommand(
            publication: publication,
            supersedingExisting: true,
            presentsFailures: true,
            managerIdentity: ObjectIdentifier(readerFileManager)
        ) { claim in
            await Self.openPublication(
                publication,
                readerFileManager: readerFileManager,
                readerPageURL: readerPageURL,
                navigator: navigator,
                readerModeViewModel: readerModeViewModel,
                allowDownload: true,
                claim: claim
            )
        }
    }

    func reconcileDownloadedPublication(
        publication: Publication,
        readerFileManager: ReaderFileManager
    ) {
        let managerIdentity = ObjectIdentifier(readerFileManager)
        let hasDifferentManager = catalogBookCommandManagerIdentities[publication.id]
            .map { $0 != managerIdentity } ?? false
        startCatalogBookCommand(
            publication: publication,
            supersedingExisting: hasDifferentManager,
            presentsFailures: false,
            managerIdentity: managerIdentity
        ) { _ in
            await Self.reconcileDownloadedPublication(
                publication,
                readerFileManager: readerFileManager
            )
        }
    }

    @discardableResult
    func startCatalogBookCommand(
        publication: Publication,
        supersedingExisting: Bool,
        presentsFailures: Bool,
        managerIdentity: ObjectIdentifier? = nil,
        operation: @escaping @MainActor (CatalogBookCommandClaim) async -> CatalogBookCommandOutcome
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        let existingTask = catalogBookCommandTasks[publication.id]
        let managerMatches = managerIdentity == nil
            || catalogBookCommandManagerIdentities[publication.id] == managerIdentity
        if !supersedingExisting, managerMatches, let existingTask {
            return existingTask
        }
        let token = beginCatalogBookCommand(
            for: publication,
            supersedingExisting: supersedingExisting || existingTask != nil,
            presentsFailures: presentsFailures,
            managerIdentity: managerIdentity
        )
        let claim = CatalogBookCommandClaim(
            isCurrentOperation: { [weak self] in
                guard let self else { return false }
                return self.catalogBookCommandGenerations[token.publicationID] == token.generation
            },
            admission: token.admission
        )
        let task = Task { @MainActor [weak self] in
            guard let self, claim.isCurrent() else { return }
            let outcome = await operation(claim)
            self.finishCatalogBookCommand(token, outcome: outcome)
        }
        catalogBookCommandTasks[publication.id] = task
        if let managerIdentity {
            catalogBookCommandManagerIdentities[publication.id] = managerIdentity
        }
        return task
    }

    func cancelCatalogBookCommands() {
        for task in catalogBookCommandTasks.values {
            task.cancel()
        }
        for admission in catalogBookLoadAdmissions.values {
            admission.retire()
        }
        catalogBookCommandTasks.removeAll()
        catalogBookLoadAdmissions.removeAll()
        catalogBookCommandManagerIdentities.removeAll()
        for publicationID in catalogBookCommandGenerations.keys {
            catalogBookCommandGenerations[publicationID, default: 0] &+= 1
        }
    }

    private func beginCatalogBookCommand(
        for publication: Publication,
        supersedingExisting: Bool,
        presentsFailures: Bool,
        managerIdentity: ObjectIdentifier?
    ) -> CatalogBookCommandToken {
        if supersedingExisting {
            catalogBookCommandTasks[publication.id]?.cancel()
        }
        catalogBookLoadAdmissions[publication.id]?.retire()
        let generation = catalogBookCommandGenerations[publication.id, default: 0] &+ 1
        catalogBookCommandGenerations[publication.id] = generation
        let admission = ReaderContentLoadAdmission()
        catalogBookLoadAdmissions[publication.id] = admission
        return CatalogBookCommandToken(
            publicationID: publication.id,
            generation: generation,
            admission: admission,
            presentsFailures: presentsFailures
        )
    }

    private func finishCatalogBookCommand(
        _ token: CatalogBookCommandToken,
        outcome: CatalogBookCommandOutcome
    ) {
        guard !Task.isCancelled,
              catalogBookCommandGenerations[token.publicationID] == token.generation
        else { return }
        catalogBookCommandTasks[token.publicationID] = nil
        catalogBookLoadAdmissions[token.publicationID] = nil
        catalogBookCommandManagerIdentities[token.publicationID] = nil
        catalogBookOutcomes[token.publicationID] = outcome
        if token.presentsFailures, let message = outcome.userFacingMessage {
            catalogBookErrorMessages[token.publicationID] = message
        } else if outcome.marksImported {
            catalogBookErrorMessages[token.publicationID] = nil
        }
        if case .navigated = outcome {
            onNavigateToReader?()
        }
    }

    private static func reconcileDownloadedPublication(
        _ publication: Publication,
        readerFileManager: ReaderFileManager
    ) async -> CatalogBookCommandOutcome {
        guard let downloadURL = publication.downloadURL else { return .failed(.noAcquisition) }
        let downloadable: Downloadable
        do {
            guard let resolved = try await readerFileManager.downloadable(url: downloadURL, name: publication.title) else {
                return .failed(.unavailable)
            }
            downloadable = resolved
        } catch {
            return .failed(.unavailable)
        }
        if downloadable.isFailed {
            return .failed(.downloadFailed(downloadable.failureMessage ?? "The book download failed."))
        }
        guard await downloadable.existsLocally() else { return .failed(.notLocal) }
        do {
            guard let importedURL = try await readerFileManager.ensureImported(downloadable: downloadable) else {
                return .failed(.missingImportResult)
            }
            return .imported(importedURL)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.importFailed(error.localizedDescription))
        }
    }

    private static func openPublication(
        _ publication: Publication,
        readerFileManager: ReaderFileManager,
        readerPageURL: URL,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel,
        allowDownload: Bool,
        claim: CatalogBookCommandClaim
    ) async -> CatalogBookCommandOutcome {
        guard let downloadURL = publication.downloadURL else { return .failed(.noAcquisition) }
        let downloadable: Downloadable
        do {
            guard let resolved = try await readerFileManager.downloadable(url: downloadURL, name: publication.title) else {
                return .failed(.unavailable)
            }
            downloadable = resolved
        } catch {
            return .failed(.unavailable)
        }
        let wasAlreadyLocal = await downloadable.existsLocally()
        if !wasAlreadyLocal {
            guard allowDownload else { return .failed(.notLocal) }
            await DownloadController.shared.ensureDownloaded([downloadable])
        }
        if downloadable.isFailed {
            return .failed(.downloadFailed(downloadable.failureMessage ?? "The book download failed."))
        }
        guard await downloadable.existsLocally() else { return .failed(.notLocal) }
        let importedURL: URL
        do {
            guard let resolved = try await readerFileManager.ensureImported(downloadable: downloadable) else {
                return .failed(.missingImportResult)
            }
            importedURL = resolved
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.importFailed(error.localizedDescription))
        }
        guard wasAlreadyLocal else { return .imported(importedURL) }
        let content: any ReaderContentProtocol
        do {
            guard let resolved = try await ReaderContentLoader.load(
                url: importedURL,
                persist: true,
                countsAsHistoryVisit: true,
                source: "BookLibraryView.openPublication",
                admission: claim.admission
            ) else {
                return .failed(.missingLoadResult)
            }
            content = resolved
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.loadFailed(error.localizedDescription))
        }
        guard !content.url.matchesReaderURL(readerPageURL) else { return .alreadyOpen(importedURL) }
        guard claim.isCurrent() else { return .superseded }
        do {
            try await navigator.load(
                content: content,
                readerFileManager: readerFileManager,
                readerModeViewModel: readerModeViewModel
            )
            guard claim.isCurrent() else { return .superseded }
            return .navigated(importedURL)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.navigationFailed(error.localizedDescription))
        }
    }

    private static func directCommandClaim() -> CatalogBookCommandClaim {
        CatalogBookCommandClaim(
            isCurrentOperation: { !Task.isCancelled },
            admission: ReaderContentLoadAdmission()
        )
    }

    /// Source-compatible direct open for callers that already own their task lifetime.
    /// The Editors' Picks rows use `startManualCatalogBookCommand` instead.
    public func open(
        publication: Publication,
        readerFileManager: ReaderFileManager = .shared,
        readerPageURL: URL,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel
    ) async throws {
        let outcome = await Self.openPublication(
            publication,
            readerFileManager: readerFileManager,
            readerPageURL: readerPageURL,
            navigator: navigator,
            readerModeViewModel: readerModeViewModel,
            allowDownload: false,
            claim: Self.directCommandClaim()
        )
        if case .navigated = outcome {
            onNavigateToReader?()
        }
        try outcome.throwIfUnsuccessful()
    }

    /// Source-compatible direct open for an already-local catalog artifact.
    public static func openDownloaded(
        publication: Publication,
        readerFileManager: ReaderFileManager = .shared,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        readerModeViewModel: ReaderModeViewModel,
        onNavigateToReader: (() -> Void)? = nil
    ) async throws {
        let outcome = await openPublication(
            publication,
            readerFileManager: readerFileManager,
            readerPageURL: readerContent.pageURL,
            navigator: navigator,
            readerModeViewModel: readerModeViewModel,
            allowDownload: false,
            claim: directCommandClaim()
        )
        if case .navigated = outcome {
            onNavigateToReader?()
        }
        try outcome.throwIfUnsuccessful()
    }
}

public enum CatalogBookCommandFailure: LocalizedError, Sendable, Equatable {
    case unavailable
    case noAcquisition
    case notLocal
    case downloadFailed(String)
    case missingImportResult
    case importFailed(String)
    case missingLoadResult
    case loadFailed(String)
    case navigationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Book storage is unavailable."
        case .noAcquisition:
            return "This book has no downloadable file."
        case .notLocal:
            return "The book download is not available locally yet."
        case .downloadFailed(let message), .importFailed(let message), .loadFailed(let message),
             .navigationFailed(let message):
            return message
        case .missingImportResult:
            return "The downloaded book could not be added to your library."
        case .missingLoadResult:
            return "The imported book could not be opened."
        }
    }
}

public enum CatalogBookCommandOutcome: Sendable, Equatable {
    case imported(URL)
    case navigated(URL)
    case alreadyOpen(URL)
    case cancelled
    case superseded
    case failed(CatalogBookCommandFailure)

    var marksImported: Bool {
        switch self {
        case .imported, .navigated, .alreadyOpen:
            return true
        case .cancelled, .superseded, .failed:
            return false
        }
    }

    var userFacingMessage: String? {
        switch self {
        case .failed(.unavailable): return "Book storage is unavailable."
        case .failed(.noAcquisition): return "This book has no downloadable file."
        case .failed(.notLocal): return "The book download is not available locally yet."
        case .failed(.downloadFailed(let message)): return message
        case .failed(.missingImportResult): return "The downloaded book could not be added to your library."
        case .failed(.importFailed(let message)), .failed(.loadFailed(let message)),
             .failed(.navigationFailed(let message)):
            return message
        case .failed(.missingLoadResult): return "The imported book could not be opened."
        case .imported, .navigated, .alreadyOpen, .cancelled, .superseded: return nil
        }
    }

    func throwIfUnsuccessful() throws {
        switch self {
        case .imported, .navigated, .alreadyOpen:
            return
        case .cancelled, .superseded:
            throw CancellationError()
        case .failed(let failure):
            throw failure
        }
    }
}

public struct CatalogBookRefreshOutcome: Sendable, Equatable {
    public let outcomes: [String: CatalogBookCommandOutcome]

    public init(outcomes: [String: CatalogBookCommandOutcome]) {
        self.outcomes = outcomes
    }
}

public struct Publication: Identifiable, Hashable, Sendable {
    public var title: String
    public var author: String?
    public var publicationDate: Date?
    public var coverURL: URL?
    public var downloadURL: URL?
    public var summary: String?
    public var hasContentAudio = false
    /// Stable presentation identity supplied by a catalog mapper, or derived once at initialization.
    public let catalogRowID: String

    public init(
        title: String,
        author: String? = nil,
        publicationDate: Date? = nil,
        coverURL: URL? = nil,
        downloadURL: URL? = nil,
        summary: String? = nil,
        hasContentAudio: Bool = false,
        catalogRowID: String? = nil
    ) {
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.coverURL = coverURL
        self.downloadURL = downloadURL
        self.summary = summary
        self.hasContentAudio = hasContentAudio
        self.catalogRowID = catalogRowID ?? Self.legacyCatalogRowID(
            title: title,
            author: author,
            publicationDate: publicationDate,
            coverURL: coverURL,
            downloadURL: downloadURL,
            summary: summary,
            hasContentAudio: hasContentAudio
        )
    }

    public var id: String {
        catalogRowID
    }

    private static func legacyCatalogRowID(
        title: String,
        author: String?,
        publicationDate: Date?,
        coverURL: URL?,
        downloadURL: URL?,
        summary: String?,
        hasContentAudio: Bool
    ) -> String {
        if let downloadURL {
            return "download:\(downloadURL.absoluteString)"
        }
        let components = [
            "catalog",
            title,
            author ?? "",
            publicationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            coverURL?.absoluteString ?? "",
            summary ?? "",
            hasContentAudio ? "audio" : "silent",
        ]
        return components.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
