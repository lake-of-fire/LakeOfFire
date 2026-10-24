import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

@MainActor
class LibraryScriptsListViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?
    @Published var userScripts: [UserScript]? = nil
    
    nonisolated(unsafe) private var cancellables = Set<AnyCancellable>()
    
    init(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration,
        observesRealm: Bool = true
    ) {
        guard observesRealm else { return }
        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            let libraryChanges = realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
            let scriptChanges = realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
            // Disabling a script preserves its Library slot. Observe the row
            // as well as membership so its Disabled label still refreshes.
            libraryChanges.merge(with: scriptChanges)
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
                            realmConfiguration: realmConfiguration
                        )
                        let libraryConfigurationID = libraryConfiguration.id
                        let userScriptIDs = Array(libraryConfiguration.getUserScripts() ?? []).map { $0.id }
                        
                        try await { @MainActor [weak self] in
                            guard let self else { return }
                            let realm = try await Realm.open(configuration: realmConfiguration)
                            self.userScripts = userScriptIDs.compactMap { realm.object(ofType: UserScript.self, forPrimaryKey: $0) }
                            self.libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID)
                        }()
                    }
                })
                .store(in: &self.cancellables)
        }
    }
    
    @discardableResult
    func deleteScript(
        at offsets: IndexSet,
        selection: LibraryScriptListSelection,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Bool, Error> {
        Task { @RealmBackgroundActor in
            try await selection.delete(at: offsets, beforeWrite: beforeWrite)
        }
    }

    @discardableResult
    func moveScripts(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        selection: LibraryScriptListSelection,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Bool, Error> {
        Task { @RealmBackgroundActor in
            try await selection.move(fromOffsets: offsets, toOffset: destination, beforeWrite: beforeWrite)
        }
    }

}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryScriptsListView: View {
    @Binding var selectedScript: UserScript?
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 50
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 32
#endif
    
    @StateObject private var viewModel = LibraryScriptsListViewModel()
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var addScriptButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    @MainActor @ViewBuilder func list(libraryConfiguration: LibraryConfiguration, userScripts: [UserScript]) -> some View {
        let selection = LibraryScriptListSelection(configuration: libraryConfiguration, scripts: userScripts)
        ScrollViewReader { scrollProxy in
            List {
                ForEach(userScripts) { script in
                    NavigationLink(value: script) {
                        VStack(alignment: .leading) {
                            Group {
                                if script.title.isEmpty {
                                    Text("Untitled Script")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(script.title)
                                }
                            }
                            .foregroundColor(script.isArchived ? .secondary : .primary)
                            Group {
                                if script.isArchived {
                                    Text("Disabled")
                                        .foregroundColor(.secondary)
                                } else {
                                    if let opmlURL = script.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
                                        Text("Official Manabi Reader system script")
                                            .bold()
                                    } else {
                                        if script.allowedDomainIDs.isEmpty {
                                            Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
                                        }
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                    //                    .listRowSeparator(.hidden)
                    .deleteDisabled(!script.isUserEditable)
                    .moveDisabled(!script.isUserEditable)
                    //                    .id("library-sidebar-\(script.id.uuidString)")
                }
                .onMove { offsets, destination in
                    guard let selection else { return }
                    viewModel.moveScripts(fromOffsets: offsets, toOffset: destination, selection: selection)
                }
                .onDelete { offsets in
                    guard let selection else { return }
                    viewModel.deleteScript(at: offsets, selection: selection)
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addScriptButton(scrollProxy: scrollProxy)
                        .buttonStyle(.borderless)
                        .padding()
                    Spacer(minLength: 0)
                }
            }
#endif
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: addScriptButtonPlacement) {
                    addScriptButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
    
    var body: some View {
//        Text("Hm \(viewModel.userScripts?.debugDescription ?? "-") \(viewModel.libraryConfiguration?.debugDescription ?? "-")")
        if let libraryConfiguration = viewModel.libraryConfiguration, let userScripts = viewModel.userScripts {
            list(libraryConfiguration: libraryConfiguration, userScripts: userScripts)
        }
    }
    
    @ViewBuilder
    func addScriptButton(scrollProxy: ScrollViewProxy) -> some View {
        let button = Button {
            Task { @MainActor in
                let scriptID = try await { @RealmBackgroundActor in
                    try await LibraryDataManager.shared.createEmptyScript(addToLibrary: true)
                }()
                scrollProxy.scrollTo("library-sidebar-\(scriptID.uuidString)")
            }
        } label: {
            Label("Add Script", systemImage: "plus.circle")
                .bold()
        }

        if #available(iOS 26, macOS 26, *) {
            button
                .labelStyle(.titleOnly)
                .keyboardShortcut("n", modifiers: [.command])
        } else {
            button
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.command])
        }
    }
}
