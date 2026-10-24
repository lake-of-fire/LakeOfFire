import SwiftUI
import RealmSwift
import Combine
import SwiftUtilities
import OPML
import UniformTypeIdentifiers
import RealmSwiftGaps
import LakeKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public enum LibraryRoute: Hashable, Codable {
    case userScripts
}

//
//extension Array<LibraryRoute>: RawRepresentable {
////extension LibraryRoute: RawRepresentable {
////public extension Array<LibraryRoute> {
//    public init?(rawValue: String) {
//        guard let data = rawValue.data(using: .utf8),
//              let result = try? JSONDecoder().decode([Element].self, from: data)
//        else {
//            return nil
//        }
//        self = result
//    }
//
//    public var rawValue: String {
//        guard let data = try? JSONEncoder().encode(self),
//              let result = String(data: data, encoding: .utf8)
//        else {
//            return "[]"
//        }
//        return result
//    }
//}
struct LibraryManagerViewModelEnvironmentModifier: ViewModifier {
    @available(iOS 16, macOS 13, *)
    struct ActiveLibraryManagerViewModelEnvironmentModifier: ViewModifier {
        @ObservedObject private var libraryViewModel = LibraryManagerViewModel.shared
        
        func body(content: Content) -> some View {
            content
                .environmentObject(libraryViewModel)
        }
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content
                .modifier(ActiveLibraryManagerViewModelEnvironmentModifier())
        } else {
            content
        }
    }
}

public extension View {
    func libraryManagerViewModelEnvironment() -> some View {
        modifier(LibraryManagerViewModelEnvironmentModifier())
    }
}

struct LibraryManagerSheetModifier: ViewModifier {
    let isActive: Bool
    
    @available(iOS 16, macOS 13, *)
    struct ActiveLibrarySheetModifier: ViewModifier {
        let isActive: Bool
        
        @ObservedObject private var libraryViewModel = LibraryManagerViewModel.shared
        
        func body(content: Content) -> some View {
            content
                .sheet(isPresented: $libraryViewModel.isLibraryPresented.gatedBy(isActive)) {
                    if #available(iOS 16.4, macOS 13.1, *) {
                        LibraryManagerView()
#if os(macOS)
                            .frame(minWidth: 650, minHeight: 500)
#endif
                    }
                }
        }
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content
                .modifier(ActiveLibrarySheetModifier(isActive: isActive))
        } else {
            content
        }
    }
}

public extension View {
    func libraryManagerSheet(isActive: Bool) -> some View {
        modifier(LibraryManagerSheetModifier(isActive: isActive))
    }
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
public class LibraryManagerViewModel: NSObject, ObservableObject {
    public static let shared = LibraryManagerViewModel()
    
    @Published public var isLibraryPresented = false
    
    @Published var exportedOPML: OPML?
    @Published var exportedOPMLFileURL: URL?
    
//    @AppStorage("LibraryManagerViewModel.presentedCategories") var presentedCategories = [LibraryRoute]()
    @Published var selectedFeed: Feed? {
        didSet {
            if let selectedFeed {
                duplicateRequestID = nil
                if let request = captureDetailSelection(feed: selectedFeed) {
                    detailSelectionRequest = request
                } else {
                    self.selectedFeed = nil
                    if case .feed = detailSelectionRequest.target {
                        detailSelectionRequest = .init(target: .none)
                    }
                }
            } else if case .feed = detailSelectionRequest.target {
                duplicateRequestID = nil
                detailSelectionRequest = .init(target: .none)
            }
        }
    }
    @Published private(set) var detailSelectionRequest = LibraryDetailSelectionRequest(target: .none)
    
    private var exportOPMLTask: Task<Void, Never>?
    private var exportOPMLGeneration = 0
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var selectedScript: UserScript? {
        didSet {
            if let selectedScript {
                duplicateRequestID = nil
                if let request = captureDetailSelection(script: selectedScript) {
                    detailSelectionRequest = request
                } else {
                    self.selectedScript = nil
                    if case .script = detailSelectionRequest.target {
                        detailSelectionRequest = .init(target: .none)
                    }
                }
            } else if case .script = detailSelectionRequest.target {
                duplicateRequestID = nil
                detailSelectionRequest = .init(target: .none)
            }
        }
    }
    @Published public var navigationPath = NavigationPath()
    // The library presentation change publishes the initial value. Avoid invalidating
    // the off-screen library graph when its configuration loads during app startup.
    var libraryConfiguration: LibraryConfiguration?
    
    @RealmBackgroundActor
    private var objectNotificationToken: NotificationToken?

    private nonisolated let realmConfiguration: Realm.Configuration
    private nonisolated let realmStorageAdmission: RealmStorageAdmission
    private var duplicateRequestID: UUID?
    
    var exportableOPML: OPML {
        return exportedOPML ?? OPML(entries: [])
    }

    public override init() {
        let realmConfiguration = LibraryDataManager.realmConfiguration
        self.realmConfiguration = realmConfiguration
        realmStorageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        super.init()
        observeRealm()
    }

    init(observesRealm: Bool) {
        let realmConfiguration = LibraryDataManager.realmConfiguration
        self.realmConfiguration = realmConfiguration
        realmStorageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        super.init()
        if observesRealm {
            observeRealm()
        }
    }

    private func selectionRealmIsCurrent(_ realm: Realm) -> Bool {
        let actor = RealmBackgroundActor.shared
        guard actor.realmCacheKey(for: realm.configuration)
                == actor.realmCacheKey(for: realmConfiguration) else { return false }
        return realmStorageAdmission.matchesCurrentStorageIdentity {
            actor.realmCacheKey(for: realmConfiguration)
        }
    }

    private func liveSelectionObject<T: Object>(_ object: T) -> T? {
        guard !object.isInvalidated, !object.isFrozen,
              let realm = object.realm,
              selectionRealmIsCurrent(realm) else { return nil }
        return object
    }

    private func refreshedSelectionObject<T: Object>(
        _ object: T, for request: LibraryDetailSelectionRequest
    ) -> T? {
        guard detailSelectionRequest == request,
              let live = liveSelectionObject(object),
              let realm = live.realm else { return nil }
        if !realm.isInWriteTransaction {
            _ = realm.refresh()
        }
        // Refresh may synchronously deliver a notification selecting another
        // row. Never let that older callback publish or clear its successor.
        guard detailSelectionRequest == request else { return nil }
        return liveSelectionObject(live)
    }

    private func captureDetailSelection(feed: Feed) -> LibraryDetailSelectionRequest? {
        guard let feed = liveSelectionObject(feed), !feed.isDeleted,
              let categoryID = feed.categoryID,
              let category = feed.realm?.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              !category.isInvalidated, !category.isDeleted else { return nil }
        return .init(target: .feed(
            id: feed.id, createdAt: feed.createdAt,
            categoryID: categoryID, categoryCreatedAt: category.createdAt
        ))
    }

    private func captureDetailSelection(script: UserScript) -> LibraryDetailSelectionRequest? {
        guard let script = liveSelectionObject(script), !script.isDeleted else { return nil }
        return .init(target: .script(id: script.id, createdAt: script.createdAt))
    }

    private func selectedFeed(for request: LibraryDetailSelectionRequest) -> Feed? {
        guard detailSelectionRequest == request,
              case .feed(let id, let createdAt, let categoryID, let categoryCreatedAt) = request.target,
              let candidate = selectedFeed,
              let feed = refreshedSelectionObject(candidate, for: request), !feed.isDeleted,
              feed.id == id, feed.createdAt == createdAt, feed.categoryID == categoryID,
              let category = feed.realm?.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              !category.isInvalidated, !category.isDeleted,
              category.createdAt == categoryCreatedAt else { return nil }
        return feed
    }

    private func selectedScript(for request: LibraryDetailSelectionRequest) -> UserScript? {
        guard detailSelectionRequest == request,
              case .script(let id, let createdAt) = request.target,
              let candidate = selectedScript,
              let script = refreshedSelectionObject(candidate, for: request), !script.isDeleted,
              script.id == id, script.createdAt == createdAt else { return nil }
        return script
    }

    /// Retire only the request being handled. Clearing an inactive peer must
    /// neither replace another kind's request nor cancel a newer duplicate.
    private func clearDetailSelection(
        ifCurrent request: LibraryDetailSelectionRequest
    ) -> LibraryDetailSelectionRequest? {
        guard detailSelectionRequest == request else { return nil }
        switch request.target {
        case .feed:
            selectedFeed = nil
        case .script:
            selectedScript = nil
        case .navigation:
            detailSelectionRequest = .init(target: .none)
        case .none:
            break
        }
        let cleared = detailSelectionRequest
        guard case .none = cleared.target else { return nil }
        selectedFeed = nil
        guard detailSelectionRequest == cleared else { return nil }
        selectedScript = nil
        return detailSelectionRequest == cleared ? cleared : nil
    }

    /// The actual typed host and its production-model regressions share this
    /// boundary. A delayed callback cannot apply an older selection or clear
    /// a newer other-kind selection through its cleanup.
    func applyDetailSelectionRequest(
        _ request: LibraryDetailSelectionRequest,
        contentRoute: Binding<ContentPaneRoute?>,
        detailPath: Binding<NavigationPath>
    ) {
        guard detailSelectionRequest == request else { return }
        switch request.target {
        case .feed:
            guard selectedFeed(for: request) != nil else {
                if let cleared = clearDetailSelection(ifCurrent: request),
                   detailSelectionRequest == cleared {
                    detailPath.wrappedValue = NavigationPath()
                }
                return
            }
            selectedScript = nil
            guard detailSelectionRequest == request else { return }
            contentRoute.wrappedValue = request.contentRoute
            guard detailSelectionRequest == request else { return }
            guard let feed = selectedFeed(for: request) else {
                if let cleared = clearDetailSelection(ifCurrent: request),
                   detailSelectionRequest == cleared {
                    detailPath.wrappedValue = NavigationPath()
                }
                return
            }
            var path = NavigationPath()
            path.append(feed)
            detailPath.wrappedValue = path
        case .script:
            guard selectedScript(for: request) != nil else {
                if let cleared = clearDetailSelection(ifCurrent: request),
                   detailSelectionRequest == cleared {
                    detailPath.wrappedValue = NavigationPath()
                }
                return
            }
            selectedFeed = nil
            guard detailSelectionRequest == request else { return }
            contentRoute.wrappedValue = request.contentRoute
            guard detailSelectionRequest == request else { return }
            guard let script = selectedScript(for: request) else {
                if let cleared = clearDetailSelection(ifCurrent: request),
                   detailSelectionRequest == cleared {
                    detailPath.wrappedValue = NavigationPath()
                }
                return
            }
            var path = NavigationPath()
            path.append(script)
            detailPath.wrappedValue = path
        case .none:
            if let cleared = clearDetailSelection(ifCurrent: request),
               detailSelectionRequest == cleared {
                detailPath.wrappedValue = NavigationPath()
            }
        case .navigation:
            break // The host already installed this user-selected path.
        }
    }

    func synchronizeInitialDetailSelection(
        hasSynchronized: Binding<Bool>,
        contentRoute: Binding<ContentPaneRoute?>,
        detailPath: Binding<NavigationPath>
    ) {
        guard !hasSynchronized.wrappedValue else { return }
        hasSynchronized.wrappedValue = true
        applyDetailSelectionRequest(detailSelectionRequest, contentRoute: contentRoute, detailPath: detailPath)
    }

    /// Sidebar intent is synchronous, including nil-to-nil selection. It
    /// retires a committed duplicate still awaiting publication before the
    /// user-selected route is installed.
    func selectContentRoute(
        _ route: ContentPaneRoute?,
        contentRoute: Binding<ContentPaneRoute?>,
        detailPath: Binding<NavigationPath>
    ) {
        duplicateRequestID = nil
        guard clearDetailSelection(ifCurrent: detailSelectionRequest) != nil else { return }
        let request = LibraryDetailSelectionRequest(target: .none)
        detailSelectionRequest = request
        guard detailSelectionRequest == request else { return }
        contentRoute.wrappedValue = route
        guard detailSelectionRequest == request else { return }
        detailPath.wrappedValue = NavigationPath()
    }

    /// NavigationLink pushes and user pops use this host binding without
    /// assigning selectedFeed/selectedScript. Retire older publication while
    /// preserving the typed path the user just chose and its existing route.
    func selectDetailPath(
        _ path: NavigationPath,
        detailPath: Binding<NavigationPath>
    ) {
        duplicateRequestID = nil
        guard clearDetailSelection(ifCurrent: detailSelectionRequest) != nil else { return }
        let request = LibraryDetailSelectionRequest(target: .navigation)
        detailSelectionRequest = request
        guard detailSelectionRequest == request else { return }
        detailPath.wrappedValue = path
    }

    private func observeRealm() {
        let realmConfiguration = self.realmConfiguration
        let realmStorageAdmission = self.realmStorageAdmission
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: realmConfiguration,
                storageAdmission: realmStorageAdmission
            )

            let exportableTypes: [ObjectBase.Type] = [FeedCategory.self, Feed.self, LibraryConfiguration.self]
            for objectType in exportableTypes {
                guard let objectType = objectType as? Object.Type else { continue }
                realm.objects(objectType)
                    .collectionPublisher
                    .subscribe(on: libraryDataQueue)
                    .map { @Sendable _ in }
                    .receive(on: RunLoop.main)
                    .handleEvents(receiveOutput: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.invalidateOPMLExport()
                        }
                    })
                    .sink(
                        receiveCompletion: { @Sendable _ in },
                        receiveValue: { @Sendable _ in }
                    )
                    .store(in: &cancellables)
            }
            
            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.2), scheduler: RunLoop.main)
                .sink(
                    receiveCompletion: { @Sendable _ in },
                    receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.objectWillChange.send()
                        }
                    }
                )
                .store(in: &cancellables)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: RunLoop.main)
                .sink(
                    receiveCompletion: { @Sendable _ in },
                    receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let currentConfigurationID = self.libraryConfiguration?.id
                            let newLibraryConfigurationID = try await { @RealmBackgroundActor in
                                try await LibraryConfiguration.getConsolidatedOrCreate(
                                    realmConfiguration: realmConfiguration
                                ).id
                            }()
                            if newLibraryConfigurationID != currentConfigurationID {
                                let realm = try await Realm.open(configuration: realmConfiguration)
                                guard let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: newLibraryConfigurationID) else { return }
                                if self.isLibraryPresented {
                                    self.objectWillChange.send()
                                }
                                self.libraryConfiguration = libraryConfiguration
                            } else if self.isLibraryPresented {
                                self.objectWillChange.send()
                            }
                        }
                    }
                )
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    private func invalidateOPMLExport() {
        guard exportedOPML != nil || exportedOPMLFileURL != nil || exportOPMLTask != nil else { return }
        exportOPMLGeneration += 1
        exportedOPML = nil
        exportedOPMLFileURL = nil
        exportOPMLTask?.cancel()
        exportOPMLTask = nil
    }

    @MainActor
    func ensureOPMLExportPrepared() {
        guard exportedOPML == nil || exportedOPMLFileURL == nil else { return }
        guard exportOPMLTask == nil else { return }
        refreshOPMLExport()
    }

    @MainActor
    func refreshOPMLExport() {
        invalidateOPMLExport()
        let exportGeneration = exportOPMLGeneration
        exportOPMLTask = Task.detached {
            do {
                try Task.checkCancellation()
                let opml = try await LibraryDataManager.shared.exportUserOPML()
                Task { @MainActor [weak self] in
                    guard self?.exportOPMLGeneration == exportGeneration else { return }
                    try Task.checkCancellation()
                    self?.exportOPMLTask = nil
                    self?.exportedOPML = opml
                    
                    let resultURL = FileManager.default.temporaryDirectory
                        .appending(component: "ManabiReaderUserLibrary", directoryHint: .notDirectory)
                        .appendingPathExtension("opml")
                    do {
                        if FileManager.default.fileExists(atPath: resultURL.path(percentEncoded: false)) {
                            try FileManager.default.removeItem(at: resultURL)
                        }
                        let data = opml.xml.data(using: .utf8) ?? Data()
                        try data.write(to: resultURL, options: [.atomic])
                        self?.exportedOPMLFileURL = resultURL
                    } catch {
                        print("Failed to write OPML file")
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard self?.exportOPMLGeneration == exportGeneration else { return }
                    self?.exportOPMLTask = nil
                }
            }
        }
    }
    
    @RealmBackgroundActor
    func add(rssURL: URL, title: String?, toCategory categoryRef: ThreadSafeReference<FeedCategory>? = nil) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
        var category: FeedCategory?
        if let categoryRef = categoryRef {
            category = realm.resolve(categoryRef)
        }
        if category == nil {
            let categoryID = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)
            
            if let category {
                try await realm.asyncWrite {
                    category.title = "My Library"
                    category.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        guard let category = category else { return }
//        await realm.asyncRefresh()
        guard let feedID = try await LibraryDataManager.shared.createEmptyFeed(inCategory: ThreadSafeReference(to: category)) else { return }
//        await realm.asyncRefresh()
        guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
        try await realm.asyncWrite {
            feed.rssUrl = rssURL
            if let title = title {
                feed.title = title
            }
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        let assignRef = ThreadSafeReference(to: category)
        try await { @MainActor in
            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
            await realm.asyncRefresh()
            if let category = realm.resolve(assignRef) {
                navigationPath.removeLast(navigationPath.count)
                navigationPath.append(category)
                if let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) {
                    selectedFeed = feed
                }
            }
        }()
    }
    
    @RealmBackgroundActor
    func duplicate(
        feed: ThreadSafeReference<Feed>,
        inCategory category: ThreadSafeReference<FeedCategory>,
        overwriteExisting: Bool,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        beforePublication: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let requestID = try await { @MainActor in
            try Task.checkCancellation()
            let requestID = UUID()
            duplicateRequestID = requestID
            return requestID
        }()
        guard let result = try await LibraryDataManager.shared.duplicateFeedWithIdentity(
            feed,
            inCategory: category,
            overwriteExisting: overwriteExisting,
            realmConfiguration: realmConfiguration,
            storageAdmission: realmStorageAdmission,
            beforeWrite: beforeWrite
        ) else { return }
        try await { @MainActor in
            try await beforePublication?()
            guard !Task.isCancelled,
                  duplicateRequestID == requestID,
                  realmStorageAdmission.matchesCurrentStorageIdentity({
                      RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
                  }) else { return }
            let realm = try await Realm.open(configuration: realmConfiguration)
            await realm.asyncRefresh()
            guard !Task.isCancelled,
                  duplicateRequestID == requestID,
                  realmStorageAdmission.matchesCurrentStorageIdentity({
                      RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
                  }),
                  let newFeed = realm.object(ofType: Feed.self, forPrimaryKey: result.feedID),
                  newFeed.createdAt == result.feedCreatedAt, !newFeed.isDeleted,
                  newFeed.categoryID == result.categoryID,
                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: result.categoryID),
                  category.createdAt == result.categoryCreatedAt,
                  !category.isDeleted, category.isUserEditable else { return }
            selectedFeed = newFeed
        }()
    }
}
