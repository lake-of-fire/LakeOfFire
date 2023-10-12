import Foundation
import OPML
import RealmSwift
import BigSyncKit
import Combine
import SwiftUIWebView
import BackgroundAssets
import Collections
import SwiftUIDownloads
import RealmSwiftGaps

//extension URL: FailableCustomPersistable {
//    public typealias PersistedType = String
//
//    public init?(persistedValue: String) {
//        if persistedValue.isEmpty || URL(string: persistedValue) == nil {
//            self.init(string: "about:blank")
//        } else {
//            self.init(string: persistedValue)
//        }
//    }
//
//    public var persistableValue: String {
//        absoluteString
//    }
//
//    public static func _rlmDefaultValue() -> Self {
//        .init(string: "about:blank")!
//    }
//}

public class LibraryConfiguration: Object, UnownedSyncableObject {
    public static var securityApplicationGroupIdentifier = ""
    public static var downloadstDirectoryName = "library-configuration"
    public static var opmlURLs = [URL]()

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
    
    @Persisted public var categories: RealmSwift.List<FeedCategory>
    @Persisted public var userScripts: RealmSwift.List<UserScript>
    
    public lazy var systemScripts: [WebViewUserScript] = {
        return [
            Readability().userScript,
//            ManabiReaderUserScript().userScript,
            YoutubeAdBlockUserScript.userScript,
            YoutubeAdSkipUserScript.userScript,
            //            YoutubeCaptionsUserScript.userScript,
        ]
    }()
    
    public var needsSyncToServer: Bool {
        return false
    }
    
    public var userCategories: Results<FeedCategory> {
        return categories.where { $0.opmlURL == nil }
    }
    
    public var downloadables: Set<Downloadable> {
        guard !Self.securityApplicationGroupIdentifier.isEmpty else { fatalError("securityApplicationGroupIdentifier unset") }
        return Set(Self.opmlURLs.compactMap { url in
            Downloadable(
                name: "App Data (\(url.lastPathComponent))",
                groupIdentifier: Self.securityApplicationGroupIdentifier,
                parentDirectoryName: Self.downloadstDirectoryName,
                downloadMirrors: [url])
        })
    }
    
    @available(macOS 13.0, iOS 16.1, *)
    public func pendingBackgroundAssetDownloads() -> Set<BADownload> {
        Task { @MainActor in
            await DownloadController.shared.ensureDownloaded(downloadables)
        }
        return Set(downloadables.compactMap({ $0.backgroundAssetDownload(applicationGroupIdentifier: Self.securityApplicationGroupIdentifier)}))
    }
    
    public var activeWebViewUserScripts: [WebViewUserScript] {
        let scripts = Array(userScripts.where { $0.isDeleted == false && $0.isArchived == false }.map { $0.webViewUserScript })
        return scripts
    }
    
    public static var shared: LibraryConfiguration {
        let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
        if let configuration = realm.objects(LibraryConfiguration.self).first(where: { $0.isDeleted == false }) {
            return configuration
        }
        
        let configuration = LibraryConfiguration()
        safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
            realm.add(configuration, update: .modified)
        }
        return configuration
    }
    
    public override init() {
        super.init()
    }
}

extension OPMLEntry {
    func attributeBoolValue(_ name: String) -> Bool? {
        guard let value = attributes?.first(where: { $0.name == name })?.value else { return nil }
        return value == "true"
    }
    
    func attributeStringValue(_ name: String) -> String? {
        return attributes?.first(where: { $0.name == name })?.value
    }
}

public class LibraryDataManager: NSObject {
    public static let shared = LibraryDataManager()
    
    public static var realmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var currentUsername: String? = nil

    var cancellables = Set<AnyCancellable>()
    
    private static let attributeCharacterSet: CharacterSet = .alphanumerics.union(.punctuationCharacters.union(.symbols.union(.whitespaces)))
    
    public override init() {
        super.init()
        // TODO: Optimize a lil by only importing changed downloads, not reapplying all downloads on any one changing. Tho it's nice to ensure DLs continuously correctly placed.
//        Task { @MainActor in
            DownloadController.shared.$finishedDownloads
                .removeDuplicates()
                .sink(receiveValue: { [weak self] feedDownloads in
                    Task.detached { [weak self] in
                        for download in feedDownloads.filter({ $0.url.lastPathComponent.hasSuffix(".opml") }) {
                            do {
                                try self?.importOPML(download: download)
                            } catch {
                                print("Failed to import OPML downloaded from \(download.url). Error: \(error.localizedDescription)")
                            }
                        }
                    }
                })
                .store(in: &cancellables)
//        }

//        DownloadController.shared.finishedDownloads.publisher
//            .print("FOOBAR ")
//            .collect()
//            .removeDuplicates()
//            .combineLatest(DownloadController.shared.failedDownloads.publisher.collect().removeDuplicates())
//            .compactMap { (finishedDownloads: [Downloadable], failedDownloads: [Downloadable]) -> [Downloadable]? in
//                if LibraryConfiguration.shared.downloadables.allSatisfy({
//                    finishedDownloads.contains($0) || failedDownloads.contains($0)
//                }) {
//                    return finishedDownloads.filter {
//                        LibraryConfiguration.shared.downloadables.contains($0)
//                    }
//                }
//                return nil
//            }
//            .removeDuplicates()
//            .sink(receiveValue: { [weak self] feedDownloads in
//                Task.detached { [weak self] in
//                    for download in feedDownloads {
//                        print(download.url)
//                        do {
//                            try self?.importOPML(download: download)
//                        } catch {
//                            print("Failed to import OPML downloaded from \(download.url). Error: \(error.localizedDescription)")
//                        }
//                    }
//                }
//            })
//            .store(in: &cancellables)
        
//        Task { @MainActor in
            let realm = try! Realm(configuration: Self.realmConfiguration)
            realm.objects(UserScript.self)
                .changesetPublisher
                .debounce(for: .seconds(0.1), scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] changes in
                    switch changes {
                    case .initial(_):
                        self?.refreshScripts()
                    case .update(_, deletions: _, insertions: _, modifications: _):
                        self?.refreshScripts()
                    case .error(let error):
                        print(error.localizedDescription)
                    }
                }
                .store(in: &cancellables)
//        }
    }
    
    private func refreshScripts() {
        safeWrite(LibraryConfiguration.shared) { (realm: Realm?, configuration: LibraryConfiguration) in
            let realm = try! realm ?? Realm(configuration: Self.realmConfiguration)
            for script in realm.objects(UserScript.self) {
                if script.isDeleted {
                    for (idx, candidate) in Array(configuration.userScripts).enumerated() {
                        if candidate.id == script.id {
                            configuration.userScripts.remove(at: idx)
                        }
                    }
                } else if !configuration.userScripts.contains(script) {
                    configuration.userScripts.append(script)
                }
            }
        }
    }
    
    public func createEmptyCategory(addToLibrary: Bool) -> FeedCategory {
        let category = FeedCategory()
        safeWrite(configuration: Self.realmConfiguration) { realm in
            realm.add(category, update: .modified)
        }
        if addToLibrary {
            safeWrite(LibraryConfiguration.shared) { _, configuration in
                configuration.categories.append(category)
            }
        }
        return category
    }
    
    public func createEmptyFeed(inCategory category: FeedCategory) -> Feed {
        let feed = Feed()
        feed.category = category
        feed.meaningfulContentMinLength = 0
        safeWrite(configuration: Self.realmConfiguration) { realm in
            realm.add(feed, update: .modified)
        }
        return feed
    }
    
    public func duplicateFeed(_ feed: Feed, inCategory category: FeedCategory, overwriteExisting: Bool) throws -> Feed {
        let realm = try! Realm(configuration: Self.realmConfiguration)
        let existing = category.feeds.filter { $0.isDeleted == false && $0.rssUrl == feed.rssUrl && $0.id != feed.id }.first
        let value = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feed))
        value.id = (overwriteExisting ? existing?.id : nil) ?? UUID()
        value.modifiedAt = Date()
        value.isDeleted = false
        value.isArchived = false
        value.category = category
        var new: Feed?
        try! realm.write {
            new = realm.create(Feed.self, value: value, update: .modified)
        }
        return new!
    }
    
    public func createEmptyScript(addToLibrary: Bool) -> UserScript {
        let script = UserScript()
        script.title = "Untitled"
        if addToLibrary {
            safeWrite(configuration: Self.realmConfiguration) { realm in
                realm.add(script, update: .modified)
            }
            safeWrite(LibraryConfiguration.shared) { _, configuration in
                configuration.userScripts.append(script)
            }
        }
        return script
    }
    
    public func syncFromServers(isWaiting: Bool) {
        let downloadables = LibraryConfiguration.shared.downloadables
        Task { @MainActor in
            await DownloadController.shared.ensureDownloaded(downloadables)
        }
    }
    
    public func importOPML(fileURLs: [URL]) {
        for fileURL in fileURLs {
            do {
                try importOPML(fileURL: fileURL)
            } catch {
                print("Failed to import OPML from local file \(fileURL.absoluteString). Error: \(error.localizedDescription)")
            }
        }
    }
    
    public func importOPML(fileURL: URL, fromDownload download: Downloadable? = nil) throws {
        let text = try String(contentsOf: fileURL)
        let opml = try OPML(Data(text.utf8))
        var allImportedCategories = OrderedSet<FeedCategory>()
        var allImportedFeeds = OrderedSet<Feed>()
        var allImportedScripts = OrderedSet<UserScript>()
        let configuration = LibraryConfiguration.shared
        
        for entry in opml.entries {
            let (importedCategories, importedFeeds, importedScripts) = importOPMLEntry(entry, opml: opml, download: download)
            allImportedCategories.formUnion(importedCategories)
            allImportedFeeds.formUnion(importedFeeds)
            allImportedScripts.formUnion(importedScripts)
        }
        
        let allImportedCategoryIDs = allImportedCategories.map { $0.id }
        let allImportedFeedIDs = allImportedFeeds.map { $0.id }
        let allImportedScriptIDs = allImportedScripts.map { $0.id }
        let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
        
        // Delete orphan scripts
        if let downloadURL = download?.url {
            let filteredScripts = realm.objects(UserScript.self).filter({ $0.isDeleted == false && $0.opmlURL == downloadURL })
            for script in filteredScripts {
                if !allImportedScriptIDs.contains(script.id) {
                    safeWrite(script) { _, script in
                        script.isDeleted = true
                    }
                }
            }
        }
        
        // Add new scripts
        for script in allImportedScripts {
            if !configuration.userScripts.contains(script) {
                var lastNeighborIdx = configuration.userScripts.count - 1
                if let downloadURL = download?.url {
                    lastNeighborIdx = configuration.userScripts.lastIndex(where: { $0.opmlURL == downloadURL }) ?? lastNeighborIdx
                }
                safeWrite(configuration) { _, configuration in
                    configuration.userScripts.insert(script, at: lastNeighborIdx + 1)
                }
            }
        }
        
        // Move scripts
        var desiredScripts = allImportedScripts
        for (idx, script) in configuration.userScripts.enumerated() {
            if let downloadURL = download?.url, script.opmlURL == downloadURL, !desiredScripts.isEmpty {
                let desiredScript = desiredScripts.removeFirst()
                if let fromIdx = configuration.userScripts.firstIndex(of: desiredScript), fromIdx != idx {
                    safeWrite(configuration) { _, configuration in
                        configuration.userScripts.move(from: fromIdx, to: idx)
                    }
                }
            }
        }
        
        // Delete orphan categories
        if let downloadURL = download?.url {
            let filteredCategories = realm.objects(FeedCategory.self).filter({ $0.isDeleted == false && $0.opmlURL == downloadURL })
            for category in filteredCategories {
                if !allImportedCategoryIDs.contains(category.id) {
                    safeWrite(category) { _, category in
                        category.isDeleted = true
                    }
                }
            }
        }
        
        // Delete orphan feeds
        if let downloadURL = download?.url {
            let filteredFeeds = realm.objects(Feed.self).filter({ $0.isDeleted == false && $0.category?.opmlURL == downloadURL })
            for feed in filteredFeeds {
                if !allImportedFeedIDs.contains(feed.id) {
                    safeWrite(feed) { _, feed in
                        feed.isDeleted = true
                    }
                }
            }
        }
       
        // Add new categories
        safeWrite(configuration) { _, configuration in
            for category in allImportedCategories {
                if !configuration.categories.map({ $0.id }).contains(category.id) {
                    var lastNeighborIdx = configuration.categories.count - 1
                    if let downloadURL = download?.url {
                        lastNeighborIdx = configuration.categories.lastIndex(where: { $0.opmlURL == downloadURL }) ?? lastNeighborIdx
                    }
                    configuration.categories.insert(category, at: lastNeighborIdx + 1)
                }
            }
        }
        
        // Move categories
        safeWrite(configuration) { _, configuration in
            var desiredCategories = allImportedCategories
            for (idx, category) in configuration.categories.enumerated() {
                if allImportedCategories.map({ $0.id }).contains(category.id), !desiredCategories.isEmpty {
                    let desiredCategory = desiredCategories.removeFirst()
                    if let fromIdx = configuration.categories.map({ $0.id }).firstIndex(of: desiredCategory.id), fromIdx != idx {
                        configuration.categories.move(from: fromIdx, to: idx)
                    }
                }
            }
        }
    }
    
    public func importOPML(download: Downloadable) throws {
        try importOPML(fileURL: download.localDestination, fromDownload: download)
    }
    
    func importOPMLEntry(_ opmlEntry: OPMLEntry, opml: OPML, download: Downloadable?, category: FeedCategory? = nil, importedCategories: OrderedSet<FeedCategory> = OrderedSet(), importedFeeds: OrderedSet<Feed> = OrderedSet(), importedScripts: OrderedSet<UserScript> = OrderedSet()) -> (OrderedSet<FeedCategory>, OrderedSet<Feed>, OrderedSet<UserScript>) {
        var category = category
        var importedCategories = importedCategories
        var importedFeeds = importedFeeds
        var importedScripts = importedScripts
        var uuid: UUID?
        if let rawUUID = opmlEntry.attributeStringValue("uuid") {
            uuid = UUID(uuidString: rawUUID)
        }
        
        if opmlEntry.feedURL != nil {
            safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                if let uuid = uuid, let feed = realm.object(ofType: Feed.self, forPrimaryKey: uuid) {
                    if feed.category?.opmlURL == download?.url || feed.isDeleted {
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, feed: feed, category: category)
                        importedFeeds.append(feed)
                    }
                } else if opmlEntry.feedURL != nil {
                    let feed = Feed()
                    if let uuid = uuid, feed.realm == nil {
                        feed.id = uuid
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, feed: feed, category: category)
                        realm.add(feed, update: .modified)
                        importedFeeds.append(feed)
                    }
                }
            }
        } else if !(opmlEntry.attributeStringValue("script")?.isEmpty ?? true) {
            safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                if let uuid = uuid, let script = realm.objects(UserScript.self).filter({ $0.id == uuid }).first {
                    if script.opmlURL == download?.url || script.isDeleted {
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, script: script)
                        Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script)
                        importedScripts.append(script)
                    }
                } else {
                    let script = UserScript()
                    if let uuid = uuid, script.realm == nil {
                        script.id = uuid
                        if let downloadURL = download?.url {
                            script.opmlURL = downloadURL
                        }
                        Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, script: script)
                        realm.add(script, update: .modified)
                        Self.applyScriptDomains(opml: opml, opmlEntry: opmlEntry, script: script)
                        importedScripts.append(script)
                    }
                }
            }
        } else if !(opmlEntry.children?.isEmpty ?? true) {
            let opmlTitle = opmlEntry.title ?? opmlEntry.text
            if category == nil, !(opmlEntry.attributes?.contains(where: { $0.name == "isUserScriptList" }) ?? false) {
                safeWrite(configuration: LibraryDataManager.realmConfiguration) { realm in
                    if let uuid = uuid, let existingCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: uuid) {
                        category = existingCategory
//                        if existingCategory.opmlURL == download?.url || existingCategory.isDeleted {
                            Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, category: existingCategory)
                            importedCategories.append(existingCategory)
//                        }
                    } else if let uuid = uuid {
                        category = FeedCategory()
                        if let category = category {
                            category.id = uuid
                            if let downloadURL = download?.url {
                                category.opmlURL = downloadURL
                            }
                            Self.applyAttributes(opml: opml, opmlEntry: opmlEntry, download: download, category: category)
                            realm.add(category, update: .modified)
                            importedCategories.append(category)
                        }
                    }
                }
            }// else if let category = category {
                // Ignore/flatten nested categories from OPML.
            //}
        }
        
        for childEntry in (opmlEntry.children ?? []) {
            let (newCategories, newFeeds, newScripts) = importOPMLEntry(childEntry, opml: opml, download: download, category: category, importedCategories: importedCategories, importedFeeds: importedFeeds, importedScripts: importedScripts)
            importedCategories.append(contentsOf: newCategories)
            importedFeeds.append(contentsOf: newFeeds)
            importedScripts.append(contentsOf: newScripts)
        }
        return (importedCategories, importedFeeds, importedScripts)
    }
    
    static func applyScriptDomains(opml: OPML, opmlEntry: OPMLEntry, script: UserScript) {
        guard let realm = script.realm else { return }
        let domains: [String] = opmlEntry.attributeStringValue("allowedDomains")?.split(separator: ",").compactMap { $0.removingPercentEncoding } ?? []
//        script.allowedDomains.removeAll()
        for (idx, existingDomain) in script.allowedDomains.enumerated() {
            if !domains.contains(existingDomain.domain) {
                existingDomain.isDeleted = true
                script.allowedDomains.remove(at: idx)
            } else if existingDomain.isDeleted {
                existingDomain.isDeleted = false
            }
        }
        let existingDomains = script.allowedDomains.map { $0.domain }
        for domain in domains {
            if !existingDomains.contains(domain) {
                let newDomain = UserScriptAllowedDomain()
                newDomain.domain = domain
                realm.add(newDomain, update: .modified)
                script.allowedDomains.append(newDomain)
            }
        }
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, download: Downloadable?, script: UserScript) {
        script.title = opmlEntry.text
        script.script = opmlEntry.attributeStringValue("script")?.removingPercentEncoding ?? ""
        script.injectAtStart = opmlEntry.attributeBoolValue("injectAtStart") ?? false
        script.mainFrameOnly = opmlEntry.attributeBoolValue("mainFrameOnly") ?? false
        script.sandboxed = opmlEntry.attributeBoolValue("sandboxed") ?? false
        script.isArchived = opmlEntry.attributeBoolValue("isArchived") ?? true
        script.previewURL = URL(string: opmlEntry.attributeStringValue("previewURL") ?? "about:blank")
        script.opmlOwnerName = opml.ownerName ?? script.opmlOwnerName
        
        script.isDeleted = false
        script.isArchived = false
        script.modifiedAt = Date()
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, download: Downloadable?, category: FeedCategory) {
        let backgroundImageURL = opmlEntry.attributeStringValue("backgroundImageUrl")
        
        let opmlTitle = opmlEntry.title ?? opmlEntry.text
        category.title = opmlTitle
        category.opmlOwnerName = opml.ownerName ?? category.opmlOwnerName
        if let backgroundImageURL = backgroundImageURL, let url = URL(string: backgroundImageURL) {
            category.backgroundImageUrl = url
        }
        category.isDeleted = false
        category.isArchived = false
        category.modifiedAt = Date()
    }
    
    static func applyAttributes(opml: OPML, opmlEntry: OPMLEntry, download: Downloadable?, feed: Feed, category: FeedCategory?) {
        guard let feedURL = opmlEntry.feedURL else { return }
        
        var iconURL: URL?
        if let iconURLRaw = opmlEntry.attributeStringValue("iconUrl") {
            iconURL = URL(string: iconURLRaw)
        }
        
        if feed.category == nil {
            feed.category = category
        }
        let opmlTitle = opmlEntry.title ?? opmlEntry.text
        feed.title = opmlTitle
        feed.markdownDescription = opmlEntry.attributeStringValue("markdownDescription") ?? feed.markdownDescription
        feed.rssUrl = feedURL
        if let iconURL = iconURL {
            feed.iconUrl = iconURL
        }
        feed.isReaderModeByDefault = opmlEntry.attributeBoolValue("isReaderModeByDefault") ?? true
        feed.rssContainsFullContent = opmlEntry.attributeBoolValue("rssContainsFullContent") ?? false
        feed.injectEntryImageIntoHeader = opmlEntry.attributeBoolValue("injectEntryImageIntoHeader") ?? false
        feed.displayPublicationDate = opmlEntry.attributeBoolValue("displayPublicationDate") ?? true
        if let meaningfulContentMinLength = opmlEntry.attributeStringValue("meaningfulContentMinLength") {
            feed.meaningfulContentMinLength = Int(meaningfulContentMinLength) ?? 0
        }
        feed.extractImageFromContent = opmlEntry.attributeBoolValue("extractImageFromContent") ?? true
        feed.isDeleted = false
        feed.isArchived = false
        feed.modifiedAt = Date()
    }
    
    public func exportUserOPML() throws -> OPML {
        let configuration = LibraryConfiguration.shared
        let userCategories = configuration.categories.filter { $0.opmlOwnerName == nil && $0.opmlURL == nil && $0.isDeleted == false }
        
        let scriptEntries = OPMLEntry(text: "User Scripts", attributes: [
            Attribute(name: "isUserScriptList", value: "true"),
        ], children: LibraryConfiguration.shared.userScripts.where({ $0.opmlURL == nil }).map({ script in
            return OPMLEntry(text: script.title, attributes: [
                Attribute(name: "uuid", value: script.id.uuidString),
                Attribute(name: "allowedDomains", value: script.allowedDomains.filter { !$0.isDeleted }.compactMap { $0.domain.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacterSet) }.joined(separator: ",")),
                Attribute(name: "script", value: script.script.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacterSet) ?? script.script),
                Attribute(name: "injectAtStart", value: script.injectAtStart ? "true" : "false"),
                Attribute(name: "mainFrameOnly", value: script.mainFrameOnly ? "true" : "false"),
                Attribute(name: "sandboxed", value: script.sandboxed ? "true" : "false"),
                Attribute(name: "isArchived", value: script.isArchived ? "true" : "false"),
                Attribute(name: "previewURL", value: script.previewURL?.absoluteString ?? "about:blank"),
            ])
        }))
        
        let opml = OPML(
            dateModified: Date(),
            ownerName: (Self.currentUsername?.isEmpty ?? true) ? nil : Self.currentUsername,
            entries: try [scriptEntries] + userCategories.map { category in
                try Task.checkCancellation()
                
                return OPMLEntry(
                    text: category.title,
                    attributes: [
                        Attribute(name: "uuid", value: category.id.uuidString),
                        Attribute(name: "backgroundImageUrl", value: category.backgroundImageUrl.absoluteString),
                        Attribute(name: "isFeedCategory", value: "true"),
                    ],
                    children: try category.feeds.where({ $0.isDeleted == false && $0.isArchived == false }).sorted(by: \.title).map { feed in
                        try Task.checkCancellation()
                        
                        var attributes = [
                            Attribute(name: "uuid", value: feed.id.uuidString),
                            Attribute(name: "extractImageFromContent", value: feed.extractImageFromContent ? "true" : "false"),
                            Attribute(name: "isReaderModeByDefault", value: feed.isReaderModeByDefault ? "true" : "false"),
                            Attribute(name: "iconUrl", value: feed.iconUrl.absoluteString),
                        ]
                        if !feed.markdownDescription.isEmpty {
                            attributes.append(Attribute(name: "markdownDescription", value: feed.markdownDescription))
                        }
                        attributes.append(Attribute(name: "rssContainsFullContent", value: feed.rssContainsFullContent ? "true" : "false"))
                        attributes.append(Attribute(name: "injectEntryImageIntoHeader", value: feed.injectEntryImageIntoHeader ? "true" : "false"))
                        attributes.append(Attribute(name: "displayPublicationDate", value: feed.displayPublicationDate ? "true" : "false"))
                        attributes.append(Attribute(name: "meaningfulContentMinLength", value: String(feed.meaningfulContentMinLength)))
                        return OPMLEntry(
                            rss: feed.rssUrl,
                            siteURL: nil,
                            title: feed.title,
                            attributes: attributes)
                    })
            })
        return opml
    }
}
