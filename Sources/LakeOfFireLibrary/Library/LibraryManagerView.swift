import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import FaviconFinder
import DebouncedOnChange
import OpenGraph
import RealmSwiftGaps
import SwiftUtilities

// SwiftUI state belongs to the originating storage and record, including when two
// Realms contain the same UUIDs.
@RealmBackgroundActor
final class LibraryEditorWriteOrdering {
    private struct Scope: Hashable {
        let storage: LibraryRecordPresentationIdentity
        let recordKind: String
    }

    private final class WeakOrdering {
        weak var value: LibraryEditorWriteOrdering?
        init(_ value: LibraryEditorWriteOrdering) { self.value = value }
    }

    @MainActor private static var activeOrderings: [Scope: WeakOrdering] = [:]
    @MainActor private var nextIssuedSequence: UInt64 = 0
    private var newestSequence: [UUID: [Int: UInt64]] = [:]

    nonisolated init() { }

    // A retired editor's command still owns this ordering. Reopening the same
    // storage must share it, so an older suspended write cannot beat a new edit.
    // Weak entries keep completed fixture/storage lifetimes out of the registry.
    @MainActor
    static func shared(configuration: Realm.Configuration, recordKind: String) -> LibraryEditorWriteOrdering {
        activeOrderings = activeOrderings.filter { $0.value.value != nil }
        // Swift bridges nil as zero; Realm's Objective-C setter converts zero
        // to the unlimited UInt.max value returned by realm.configuration.
        // Normalize all unlimited forms without collapsing finite limits.
        var orderingConfiguration = configuration
        let suppliedLimit = configuration.maximumNumberOfActiveVersions ?? 0
        orderingConfiguration.maximumNumberOfActiveVersions = suppliedLimit == 0 ? UInt.max : suppliedLimit
        let scope = Scope(
            storage: LibraryRecordPresentationIdentity(
                recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                configuration: orderingConfiguration
            ),
            recordKind: recordKind
        )
        if let ordering = activeOrderings[scope]?.value { return ordering }
        let ordering = LibraryEditorWriteOrdering()
        activeOrderings[scope] = WeakOrdering(ordering)
        return ordering
    }

    @MainActor
    func issueSequence() -> UInt64 {
        nextIssuedSequence &+= 1
        return nextIssuedSequence
    }

    // Check in the final write turn. An earlier task can resume after a newer
    // task committed, including when the newer edit was an intentional no-op.
    func admits(recordID: UUID, field: Int, sequence: UInt64) -> Bool {
        guard sequence >= (newestSequence[recordID]?[field] ?? 0) else { return false }
        newestSequence[recordID, default: [:]][field] = sequence
        return true
    }
}

struct LibraryRecordPresentationIdentity: Hashable {
    let recordID: UUID
    let ownerID: UUID?
    let storage: String
    let fileResourceIdentifier: String?
    let schemaVersion: UInt64
    let readOnly: Bool
    let encryptionKey: Data?
    let objectTypes: [String]?
    let maximumNumberOfActiveVersions: String?
    let deleteRealmIfMigrationNeeded: Bool
    let seedFilePath: URL?

    init(recordID: UUID, ownerID: UUID? = nil, configuration: Realm.Configuration) {
        self.recordID = recordID
        self.ownerID = ownerID
        storage = configuration.inMemoryIdentifier.map { "memory:" + $0 }
            ?? configuration.fileURL.map { "file:" + $0.resolvingSymlinksInPath().standardizedFileURL.path }
            ?? "default"
        fileResourceIdentifier = configuration.inMemoryIdentifier == nil
            ? configuration.fileURL.flatMap {
                (try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
                    .map { String(describing: $0) }
            }
            : nil
        schemaVersion = configuration.schemaVersion
        readOnly = configuration.readOnly
        encryptionKey = configuration.encryptionKey
        objectTypes = configuration.objectTypes?.map { String(reflecting: $0) }.sorted()
        maximumNumberOfActiveVersions = configuration.maximumNumberOfActiveVersions.map(String.init)
        deleteRealmIfMigrationNeeded = configuration.deleteRealmIfMigrationNeeded
        seedFilePath = configuration.seedFilePath?.resolvingSymlinksInPath().standardizedFileURL
    }
}

struct UserScriptAllowedDomainEditor {
    let domainID: UUID
    let scriptID: UUID
    let realmConfiguration: Realm.Configuration

    @RealmBackgroundActor
    func read() async throws -> String? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
              !script.isDeleted, script.allowedDomainIDs.contains(domainID),
              let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
              !domain.isDeleted else { return nil }
        return domain.domain
    }

    @RealmBackgroundActor
    func write(_ text: String) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        try await realm.asyncWritePreservingOwnership {
            guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
                  !script.isDeleted, script.isUserEditable, script.allowedDomainIDs.contains(domainID),
                  let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
                  !domain.isDeleted, domain.domain != text else { return }
            domain.domain = text
            domain.refreshChangeMetadata(explicitlyModified: true)
        }
    }
}

struct UserScriptAllowedDomainCell: View {
    let editor: UserScriptAllowedDomainEditor
    @State private var domainText = ""
    @State private var hasLoadedDomain = false

    init(domainID: UUID, scriptID: UUID, realmConfiguration: Realm.Configuration) {
        editor = UserScriptAllowedDomainEditor(
            domainID: domainID, scriptID: scriptID, realmConfiguration: realmConfiguration
        )
    }

    var body: some View {
        TextField("Domain", text: $domainText, prompt: Text("example.com"))
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            .onChange(of: domainText, debounceTime: 0.3) { text in
                guard hasLoadedDomain else { return }
                let editor = editor
                Task { @RealmBackgroundActor in
                    try await editor.write(text)
                }
            }
            .task {
                let editor = editor
                guard let text = try? await editor.read(), !Task.isCancelled else { return }
                domainText = text
                hasLoadedDomain = true
            }
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptForm: View {
    let script: UserScript
    
    var body: some View {
        Form {
            LibraryScriptFormSections(script: script)
                .id(LibraryRecordPresentationIdentity(
                    recordID: script.id,
                    configuration: script.realm?.configuration ?? LibraryDataManager.realmConfiguration
                ))
                .disabled(!script.isUserEditable)
        }
        .formStyle(.grouped)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryViewContainer: View {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?
    var onEditorAppear: ((LibraryCategoryViewModel) -> Void)? = nil

    var body: some View {
        LibraryCategoryView(
            category: category,
            libraryConfiguration: libraryConfiguration,
            selectedFeed: $selectedFeed,
            onEditorAppear: onEditorAppear
        )
        .id(LibraryRecordPresentationIdentity(
            recordID: category.id, ownerID: libraryConfiguration.id,
            configuration: category.realm?.configuration
                ?? libraryConfiguration.realm?.configuration
                ?? LibraryDataManager.realmConfiguration
        ))
        .task(id: [category.id, selectedFeed?.categoryID]) { @MainActor in
            if selectedFeed?.categoryID != category.id {
                selectedFeed = nil
            }
            //                        let feedsToDeselect = viewModel.selectedFeed.filter { $0.category != category }
            //                        feedsToDeselect.forEach {
            //                            viewModel.selectedFeed.remove($0)
            //                        }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    @State private var columnVisibility = LibraryManagerView.initialColumnVisibility
    @State private var compactColumn = CompactLibraryColumn.sidebar
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @State private var libraryCategoryViewModel: LibraryCategoryViewModel?
    
    public var body: some View {
        splitView
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.selectedSidebarDestination) { destination in
            Task { @MainActor in
                viewModel.navigationPath = NavigationPath()
                switch destination {
                case .none:
                    viewModel.selectedFeed = nil
                    viewModel.selectedScript = nil
                    compactColumn = .sidebar
                case .some(.userScripts):
                    viewModel.selectedFeed = nil
                    compactColumn = .detail
                case .some(.category(let categoryID)):
                    viewModel.selectedScript = nil
                    if viewModel.selectedFeed?.categoryID != categoryID {
                        viewModel.selectedFeed = nil
                    }
                    compactColumn = .detail
                }
            }
        }
        .onChange(of: viewModel.selectedFeed) { feed in
            Task { @MainActor in
                if feed != nil {
                    viewModel.selectedScript = nil
                    syncDetailNavigationPath()
                    compactColumn = .detail
                } else if viewModel.selectedScript == nil {
                    viewModel.navigationPath = NavigationPath()
                    compactColumn = viewModel.selectedSidebarDestination == nil ? .sidebar : .detail
                }
            }
        }
        .onChange(of: viewModel.selectedScript) { script in
            Task { @MainActor in
                if script != nil {
                    viewModel.selectedFeed = nil
                    syncDetailNavigationPath()
                    compactColumn = .detail
                } else if viewModel.selectedFeed == nil {
                    viewModel.navigationPath = NavigationPath()
                    compactColumn = viewModel.selectedSidebarDestination == nil ? .sidebar : .detail
                }
            }
        }
        .onChange(of: viewModel.navigationPath.count) { pathCount in
            guard pathCount == 0 else { return }
            if viewModel.selectedFeed != nil || viewModel.selectedScript != nil {
                viewModel.selectedFeed = nil
                viewModel.selectedScript = nil
            }
        }
        .task { @MainActor in
            columnVisibility = .all
            if viewModel.selectedFeed != nil || viewModel.selectedScript != nil {
                syncDetailNavigationPath()
                compactColumn = .detail
            } else if viewModel.selectedSidebarDestination == nil {
                compactColumn = .sidebar
            } else {
                compactColumn = .detail
            }
        }
    }

    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        .all
    }

    @ViewBuilder
    private var splitView: some View {
        if #available(iOS 17, macOS 14, *) {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                preferredCompactColumn: Binding(
                    get: { compactColumn.navigationSplitViewColumn },
                    set: { compactColumn = CompactLibraryColumn($0) }
                ),
                sidebar: {
                    sidebarView
                },
                detail: {
                    detailNavigationView
                }
            )
        } else {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                sidebar: {
                    sidebarView
                },
                detail: {
                    detailNavigationView
                }
            )
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        LibraryCategoriesView()
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: dismissToolbarPlacement) {
                    if horizontalSizeClass == .compact {
                        if #available(iOS 26, *) {
                            Button(role: .close) {
                                viewModel.isLibraryPresented = false
                            }
                            .tint(.primary)
                        } else {
                            Button {
                                viewModel.isLibraryPresented = false
                            } label: {
                                Text("Done")
                                    .bold()
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
#endif
#if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
#endif
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.selectedSidebarDestination {
        case .some(.category(let categoryID)):
            if let libraryConfiguration = viewModel.libraryConfiguration,
               let category = libraryConfiguration.getCategories()?.first(where: { $0.id == categoryID }) {
                LibraryCategoryViewContainer(
                    category: category,
                    libraryConfiguration: libraryConfiguration,
                    selectedFeed: $viewModel.selectedFeed
                )
            } else {
                contentPlaceholder("Select a category to edit feeds, or open user scripts.")
            }
        case .some(.userScripts):
            LibraryScriptsListView(selectedScript: $viewModel.selectedScript)
                .navigationTitle("User Scripts")
        case .none:
            contentPlaceholder("Select a category to edit feeds, or open user scripts.")
        }
    }

    @ViewBuilder
    private func contentPlaceholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .multilineTextAlignment(.center)
                .padding()
                .foregroundColor(.secondary)
                .font(.callout)
            Spacer()
        }
    }

    @ViewBuilder
    private var detailNavigationView: some View {
        NavigationStack(path: $viewModel.navigationPath) {
            contentView
                .navigationDestination(for: Feed.self) { feed in
                    feedDetailView(feed)
                }
                .navigationDestination(for: UserScript.self) { script in
                    scriptDetailView(script)
                }
        }
    }

    private func syncDetailNavigationPath() {
        var path = NavigationPath()
        if let feed = viewModel.selectedFeed {
            path.append(feed)
        } else if let script = viewModel.selectedScript {
            path.append(script)
        }
        viewModel.navigationPath = path
    }

    @ViewBuilder
    private func feedDetailView(_ feed: Feed) -> some View {
        detailFormContainer {
            LibraryFeedView(feed: feed)
                .id(LibraryRecordPresentationIdentity(
                    recordID: feed.id,
                    configuration: feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
                ))
            //                                .id("library-manager-feed-view-\(feed.id.uuidString)") // Because it's hard to reuse form instance across feed objects. ?
        }
    }

    @ViewBuilder
    private func scriptDetailView(_ script: UserScript) -> some View {
        detailFormContainer {
            LibraryScriptForm(script: script)
            //                                .id("library-manager-script-view-\(script.id.uuidString)") // Because it's hard to reuse form instance across script objects. ?
        }
    }

    @ViewBuilder
    private func detailFormContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Group {
#if os(macOS)
            ScrollView {
                content()
            }
#else
            content()
#endif
        }
#if os(macOS)
        .textFieldStyle(.roundedBorder)
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: dismissToolbarPlacement) {
                if #available(iOS 26, *) {
                    Button(role: .close) {
                        viewModel.isLibraryPresented = false
                    }
                    .tint(.primary)
                } else {
                    Button {
                        viewModel.isLibraryPresented = false
                    } label: {
                        Text("Done")
                            .bold()
                    }
                    .tint(.primary)
                }
            }
#endif
        }
    }

    public init() {
    }
}

private enum CompactLibraryColumn {
    case sidebar
    case detail

    @available(iOS 17, macOS 14, *)
    var navigationSplitViewColumn: NavigationSplitViewColumn {
        switch self {
        case .sidebar:
            return .sidebar
        case .detail:
            return .detail
        }
    }

    @available(iOS 17, macOS 14, *)
    init(_ column: NavigationSplitViewColumn) {
        switch column {
        case .sidebar:
            self = .sidebar
        case .detail:
            self = .detail
        default:
            self = .sidebar
        }
    }
}

#if os(iOS)
@available(iOS 16.0, macOS 13.0, *)
private extension LibraryManagerView {
    var dismissToolbarPlacement: ToolbarItemPlacement {
        if #available(iOS 26, *) {
            return .cancellationAction
        } else {
            return .confirmationAction
        }
    }
}
#endif
