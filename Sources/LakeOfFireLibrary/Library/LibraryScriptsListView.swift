import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import Combine
import RealmSwift
import RealmSwiftGaps

@MainActor
class LibraryScriptsListViewModel: ObservableObject {
    let realmConfiguration: Realm.Configuration

    @Published var libraryConfiguration: LibraryConfiguration?
    @Published var userScripts: [UserScript]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    init(
        observesRealm: Bool = true,
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) {
        self.realmConfiguration = realmConfiguration
        guard observesRealm else { return }
        Task { @RealmBackgroundActor [weak self] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
        }
    }

    @discardableResult
    func refreshData() -> Task<Void, Error> {
        Task { @RealmBackgroundActor [realmConfiguration] in
            let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: realmConfiguration
            )
            let libraryConfigurationID = libraryConfiguration.id
            let userScriptIDs = Array(libraryConfiguration.getUserScripts() ?? []).map(\.id)

            try await { @MainActor [weak self] in
                guard let self else { return }
                let realm = try await Realm.open(configuration: realmConfiguration)
                self.userScripts = userScriptIDs.compactMap {
                    realm.object(ofType: UserScript.self, forPrimaryKey: $0)
                }
                self.libraryConfiguration = realm.object(
                    ofType: LibraryConfiguration.self,
                    forPrimaryKey: libraryConfigurationID
                )
            }()
        }
    }
    
    @MainActor
    func deleteScript(_ script: UserScript) async throws {
        guard let libraryConfiguration else { return }
        try await deleteScript(
            scriptID: script.id,
            configurationID: libraryConfiguration.id,
            configurationCreatedAt: libraryConfiguration.createdAt
        )
    }
    
    #warning("TODO: add script restoration")
    //    func restoreScript(_ script: UserScript) {
//        guard script.isUserEditable else { return }
//        safeWrite(script) { _, script in
//            script.isArchived = false
//        }
//        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
//            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: script.id) else { return }
//            if !libraryConfiguration.userScripts.contains(script) {
//                libraryConfiguration.userScripts.append(script)
//            }
//        }
//    }
    
    @MainActor
    @discardableResult
    func deleteScript(at offsets: IndexSet) -> Task<Void, Error> {
        let scripts = userScripts ?? []
        let scriptIDs = offsets.compactMap { offset -> UUID? in
            guard scripts.indices.contains(offset), scripts[offset].isUserEditable else { return nil }
            return scripts[offset].id
        }
        let configurationID = libraryConfiguration?.id
        let configurationCreatedAt = libraryConfiguration?.createdAt
        return Task { @MainActor in
            guard let configurationID, let configurationCreatedAt else { return }
            for scriptID in scriptIDs {
                try await deleteScript(
                    scriptID: scriptID,
                    configurationID: configurationID,
                    configurationCreatedAt: configurationCreatedAt
                )
            }
        }
    }
    
    @MainActor
    @discardableResult
    func moveScripts(fromOffsets: IndexSet, toOffset: Int) -> Task<Void, Error>? {
        guard let libraryConfiguration, let userScripts else { return nil }
        let originalIDs = Array(libraryConfiguration.userScriptIDs)
        let visibleIDs = userScripts.map(\.id)
        guard !visibleIDs.isEmpty,
              Set(visibleIDs).count == visibleIDs.count,
              fromOffsets.allSatisfy(visibleIDs.indices.contains),
              fromOffsets.allSatisfy { userScripts[$0].isUserEditable },
              visibleIDs.indices.contains(toOffset) || toOffset == visibleIDs.endIndex else { return nil }
        var reorderedIDs = visibleIDs
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard reorderedIDs != visibleIDs else { return nil }
        let configurationID = libraryConfiguration.id
        let configurationCreatedAt = libraryConfiguration.createdAt
        return Task { @MainActor in
            try await Task { @RealmBackgroundActor [realmConfiguration] in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await realm.asyncWrite {
                    guard let libraryConfiguration = realm.object(
                        ofType: LibraryConfiguration.self,
                        forPrimaryKey: configurationID
                    ),
                    libraryConfiguration.createdAt == configurationCreatedAt,
                    Array(libraryConfiguration.userScriptIDs) == originalIDs else { return }
                    let visibleIDSet = Set(visibleIDs)
                    let currentVisibleIDs = originalIDs.compactMap { scriptID -> UUID? in
                        guard visibleIDSet.contains(scriptID),
                              let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
                              !script.isDeleted else { return nil }
                        return scriptID
                    }
                    guard currentVisibleIDs == visibleIDs,
                          reorderedIDs.count == currentVisibleIDs.count,
                          Set(reorderedIDs) == Set(currentVisibleIDs) else { return }
                    var nextRawIDs = originalIDs
                    var reorderedIndex = 0
                    for index in nextRawIDs.indices where visibleIDSet.contains(nextRawIDs[index]) {
                        guard reorderedIndex < reorderedIDs.count else { return }
                        nextRawIDs[index] = reorderedIDs[reorderedIndex]
                        reorderedIndex += 1
                    }
                    guard reorderedIndex == reorderedIDs.count,
                          nextRawIDs != originalIDs else { return }
                    libraryConfiguration.userScriptIDs.removeAll()
                    libraryConfiguration.userScriptIDs.append(objectsIn: nextRawIDs)
                    libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
                }
            }.value
        }
    }

    @MainActor
    func createScript() async throws -> UUID {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true,
                realmConfiguration: realmConfiguration
            )
        }.value
    }

    @MainActor
    private func deleteScript(
        scriptID: UUID,
        configurationID: UUID,
        configurationCreatedAt: Date
    ) async throws {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            guard let libraryConfiguration = realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: configurationID
            ),
            libraryConfiguration.createdAt == configurationCreatedAt,
            let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
            script.isUserEditable,
            !script.isDeleted else { return }
            try await realm.asyncWrite {
                if let index = libraryConfiguration.userScriptIDs.firstIndex(of: scriptID) {
                    libraryConfiguration.userScriptIDs.remove(at: index)
                    libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
                }
                if script.isArchived {
                    script.isDeleted = true
                    script.refreshChangeMetadata(explicitlyModified: true)
                } else {
                    script.isArchived = true
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }.value
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
    
    @ViewBuilder func list(libraryConfiguration: LibraryConfiguration, userScripts: [UserScript]) -> some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selectedScript) {
                ForEach(userScripts) { script in
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
                    .tag(script)
                    //                    .listRowSeparator(.hidden)
                    .deleteDisabled(!script.isUserEditable)
                    .moveDisabled(!script.isUserEditable)
                    //                    .id("library-sidebar-\(script.id.uuidString)")
                }
//                .onMove(perform: $libraryConfiguration.userScripts.move)
                .onMove {
                    viewModel.moveScripts(fromOffsets: $0, toOffset: $1)
                }
                .onDelete {
                    viewModel.deleteScript(at: $0)
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
                let scriptID = try await viewModel.createScript()
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
