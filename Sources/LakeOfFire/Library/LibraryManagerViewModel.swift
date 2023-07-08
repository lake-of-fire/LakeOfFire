import SwiftUI
import RealmSwift
import Combine
import OPML
import UniformTypeIdentifiers
import RealmSwiftGaps

@available(iOS 16.0, macOS 13.0, *)
extension OPML: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .fileURL, //UTType(exportedAs: "public.opml"),
                           shouldAttemptToOpenInPlace: false // url is temporary
        ) { opml in
            let resultURL = FileManager.default.temporaryDirectory
                .appending(component: UUID().uuidString, directoryHint: .notDirectory)
                .appendingPathExtension("opml")
            if FileManager.default.fileExists(atPath: resultURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: resultURL)
            }
            let data = opml.xml.data(using: .utf8) ?? Data()
            try data.write(to: resultURL, options: [.atomic])
            let sentTransferredFile: SentTransferredFile = .init(resultURL, allowAccessingOriginalFile: true)
            return sentTransferredFile
        } importing: { opmlFile in
            let data: Data = try .init(
                contentsOf: opmlFile.file,
                options: [.uncached]
            )
            return (try? OPML(data)) ?? OPML(entries: [])
        }
        
        DataRepresentation(contentType: .text) { opml in
            opml.xml.data(using: .utf8) ?? Data()
        } importing: { return (try? OPML($0)) ?? OPML(entries: []) }
            .suggestedFileName("ManabiReaderUserFeeds.opml")
        //        DataRepresentation(contentType: UTType(exportedAs: "public.opml")) { opml in
        //            opml.xml(indented: true).data(using: .utf8) ?? Data()
        //        } importing: { return (try? OPML($0)) ?? OPML(entries: []) }
//        .suggestedFileName("ManabiReaderUserFeeds.opml")
    }
}

public enum LibraryRoute: Hashable, Codable {
    case userScripts
    case category(FeedCategory)
}

extension Array<LibraryRoute>: RawRepresentable {
//extension LibraryRoute: RawRepresentable {
//public extension Array<LibraryRoute> {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

@available(iOS 16.0, macOS 13.0, *)
public class LibraryManagerViewModel: NSObject, ObservableObject {
    public static let shared = LibraryManagerViewModel()
    
    @Published var exportedOPML: OPML?
    @Published var exportedOPMLFileURL: URL?
    
    @AppStorage("LibraryManagerViewModel.presentedCategories") var presentedCategories = [LibraryRoute]()
    @Published var selectedFeed: Feed?
    
    @Published private var exportOPMLTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    @Published var selectedScript: UserScript?
    
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
    }
    
    func refreshOPMLExport() {
        exportedOPML = nil
        exportedOPMLFileURL = nil
        exportOPMLTask?.cancel()
        exportOPMLTask = Task.detached {
            do {
                try Task.checkCancellation()
                let opml = try LibraryDataManager.shared.exportUserOPML()
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
    
    func add(rssURL: URL, title: String?, toCategory category: FeedCategory? = nil) {
        var category = category?.thaw()
        if category == nil {
            category = LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            if let category = category {
                safeWrite(category, configuration: LibraryDataManager.realmConfiguration) { (_, category: FeedCategory) in
                    category.title = "User Library"
                }
            }
        }
        guard let category = category else { return }
        
        let feed = LibraryDataManager.shared.createEmptyFeed(inCategory: category)
        safeWrite(feed, configuration: LibraryDataManager.realmConfiguration) { (_, feed: Feed) in
            feed.rssUrl = rssURL
            if let title = title {
                feed.title = title
            }
        }
        presentedCategories = [LibraryRoute.category(category)]
    }
    
    func duplicate(feed: Feed, inCategory category: FeedCategory, overwriteExisting: Bool) {
        do {
            let newFeed = try LibraryDataManager.shared.duplicateFeed(feed, inCategory: category, overwriteExisting: true)
            Task { @MainActor in
                presentedCategories = [LibraryRoute.category(category)]
                selectedFeed = newFeed
            }
        } catch { }
    }
}
