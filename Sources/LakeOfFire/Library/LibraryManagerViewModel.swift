import SwiftUI
import RealmSwift
import Combine
import SwiftUtilities
import OPML
import UniformTypeIdentifiers
import RealmSwiftGaps
import LakeKit

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
    @Published var selectedFeed: Feed?
    
    @Published private var exportOPMLTask: Task<Void, Never>?
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var selectedScript: UserScript?
    @Published public var navigationPath = NavigationPath()
    @Published var libraryConfiguration: LibraryConfiguration?
    
    @RealmBackgroundActor
    private var objectNotificationToken: NotificationToken?
    
    var exportableOPML: OPML {
        return exportedOPML ?? OPML(entries: [])
    }

    public override init() {
        super.init()
        
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)

            let exportableTypes: [ObjectBase.Type] = [FeedCategory.self, Feed.self, LibraryConfiguration.self]
            for objectType in exportableTypes {
                guard let objectType = objectType as? Object.Type else { continue }
                realm.objects(objectType)
                    .collectionPublisher
                    .subscribe(on: libraryDataQueue)
                    .map { _ in }
                    .receive(on: RunLoop.main)
                    .handleEvents(receiveOutput: { [weak self] changes in
                        Task { @MainActor [weak self] in
                            self?.exportedOPML = nil
                            self?.exportedOPMLFileURL = nil
                            self?.exportOPMLTask?.cancel()
                        }
                    })
                    .debounceLeadingTrailing(for: .seconds(2), scheduler: libraryDataQueue)
                    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.refreshOPMLExport()
                        }
                    })
                    .store(in: &cancellables)
            }
            
            realm.objects(UserScript.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.2), scheduler: RunLoop.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.objectWillChange.send()
                    }
                })
                .store(in: &cancellables)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: RunLoop.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        let currentConfigurationID = libraryConfiguration?.id
                        try await { @RealmBackgroundActor in
                            let newLibraryConfigurationID = try await LibraryConfiguration.getConsolidatedOrCreate().id
                            try await { @MainActor [weak self] in
                                if newLibraryConfigurationID != currentConfigurationID {
                                    let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                                    guard let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: newLibraryConfigurationID) else { return }
                                    self?.libraryConfiguration = libraryConfiguration
                                } else {
                                    self?.objectWillChange.send()
                                }
                            }()
                        }()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    func refreshOPMLExport() {
        exportedOPML = nil
        exportedOPMLFileURL = nil
        exportOPMLTask?.cancel()
        exportOPMLTask = Task.detached {
            do {
                try Task.checkCancellation()
                let opml = try await LibraryDataManager.shared.exportUserOPML()
                Task { @MainActor [weak self] in
                    try Task.checkCancellation()
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
            } catch { }
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
            category = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            
            if let category {
                try await realm.asyncWrite {
                    category.title = "User Library"
                    category.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        guard let category = category else { return }
//        await realm.asyncRefresh()
        guard let feed = try await LibraryDataManager.shared.createEmptyFeed(inCategory: ThreadSafeReference(to: category)) else { return }
//        await realm.asyncRefresh()
        try await realm.asyncWrite {
            feed.rssUrl = rssURL
            if let title = title {
                feed.title = title
            }
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        let assignRef = ThreadSafeReference(to: category)
        let feedID = feed.id
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
    func duplicate(feed: ThreadSafeReference<Feed>, inCategory category: ThreadSafeReference<FeedCategory>, overwriteExisting: Bool) async throws {
        do {
            guard let newFeed = try await LibraryDataManager.shared.duplicateFeed(feed, inCategory: category, overwriteExisting: true) else { return }
            let feedRef = ThreadSafeReference(to: newFeed)
            Task { @MainActor in
                let realm = try await Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
                guard let category = realm.resolve(category), let newFeed = realm.resolve(feedRef) else { return }
                navigationPath.removeLast(navigationPath.count)
                navigationPath.append(category)
                selectedFeed = newFeed
            }
        } catch { }
    }
}
