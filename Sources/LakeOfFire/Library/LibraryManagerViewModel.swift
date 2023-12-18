import SwiftUI
import RealmSwift
import Combine
import OPML
import UniformTypeIdentifiers
import RealmSwiftGaps

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

@available(iOS 16.0, macOS 13.0, *)
public class LibraryManagerViewModel: NSObject, ObservableObject {
    public static let shared = LibraryManagerViewModel()
    
    @Published var exportedOPML: OPML?
    @Published var exportedOPMLFileURL: URL?
    
//    @AppStorage("LibraryManagerViewModel.presentedCategories") var presentedCategories = [LibraryRoute]()
    @Published var selectedFeed: Feed?
    
    @Published private var exportOPMLTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    @Published var selectedScript: UserScript?
    @Published var navigationPath = NavigationPath()
    @Published var libraryConfiguration: LibraryConfiguration?
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    var exportableOPML: OPML {
        return exportedOPML ?? OPML(entries: [])
    }

    public override init() {
        super.init()
        
        let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
        
        let exportableTypes: [ObjectBase.Type] = [FeedCategory.self, Feed.self, LibraryConfiguration.self]
        for objectType in exportableTypes {
            guard let objectType = objectType as? Object.Type else { continue }
            realm.objects(objectType)
                .changesetPublisher
                .handleEvents(receiveOutput: { [weak self] changes in
                    self?.exportedOPML = nil
                    self?.exportedOPMLFileURL = nil
                    self?.exportOPMLTask?.cancel()
                })
                .debounce(for: .seconds(0.05), scheduler: DispatchQueue.main, options: .init(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] changes in
                    switch changes {
                    case .initial(_):
                        self?.refreshOPMLExport()
                    case .update(_, deletions: _, insertions: _, modifications: _):
                        self?.refreshOPMLExport()
                    case .error(let error):
                        print(error.localizedDescription)
                    }
                }
                .store(in: &cancellables)
        }
        
        realm.objects(UserScript.self)
            .changesetPublisher
            .debounce(for: .seconds(0.1), scheduler: DispatchQueue.main, options: .init(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] changes in
                switch changes {
                case .initial(_):
                    self?.objectWillChange.send()
                case .update(_, deletions: _, insertions: _, modifications: _):
                    self?.objectWillChange.send()
                case .error(let error):
                    print(error.localizedDescription)
                }
            }
            .store(in: &cancellables)
        
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let libraryConfiguration = try await LibraryConfiguration.getOrCreate()
            objectNotificationToken = libraryConfiguration
                .observe { [weak self] change in
                    guard let self = self else { return }
                    switch change {
                    case .change(_, _):
                        Task { @MainActor [weak self] in
                            self?.objectWillChange.send()
                        }
                    case .error(let error):
                        print("An error occurred: \(error)")
                    case .deleted:
                        print("The object was deleted.")
                    }
                }
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.getOrCreate())
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
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
        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
        var category: FeedCategory?
        if let categoryRef = categoryRef {
            category = realm.resolve(categoryRef)
        }
        if category == nil {
            category = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
        }
        guard let category = category else { return }
        try await realm.asyncWrite {
            category.title = "User Library"
        }
        guard let feed = try await LibraryDataManager.shared.createEmptyFeed(inCategory: ThreadSafeReference(to: category)) else { return }
        try await realm.asyncWrite {
            feed.rssUrl = rssURL
            if let title = title {
                feed.title = title
            }
        }
        let assignRef = ThreadSafeReference(to: category)
        try await Task { @MainActor in
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
            if let category = realm.resolve(assignRef) {
                navigationPath.removeLast(navigationPath.count)
                navigationPath.append(category)
            }
        }.value
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
