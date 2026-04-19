import SwiftUI
import RealmSwift
import MarkdownKit
import SwiftSoup
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwiftGaps
import UniformTypeIdentifiers

private func logReaderLoad(_ message: String) {
    debugPrint("# READERLOAD \(message)")
}

private func logSnippetEvent(_ stage: String, _ parts: String...) {
    debugPrint("# SNIPPETS", stage, parts.joined(separator: " "))
}

private let readerContentLoaderVerboseLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_READERLOAD_VERBOSE_CONTENT_LOADER"] == "1"
private let readerContentLoaderSlowStepThreshold: TimeInterval = 0.010
private let readerContentLoaderSlowSummaryThreshold: TimeInterval = 0.050

@inline(__always)
private func shouldLogLoadAllStep(found: Bool, elapsed: TimeInterval) -> Bool {
    readerContentLoaderVerboseLoggingEnabled || found || elapsed >= readerContentLoaderSlowStepThreshold
}

@inline(__always)
private func shouldLogLoadAllSummary(candidateCount: Int, elapsed: TimeInterval) -> Bool {
    readerContentLoaderVerboseLoggingEnabled || candidateCount > 0 || elapsed >= readerContentLoaderSlowSummaryThreshold
}

fileprivate extension URL {
    func settingScheme(_ value: String) -> URL {
        let components = NSURLComponents.init(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = value
        return (components?.url!)!
    }
}

public extension URL {
    var isReaderURLLoaderURL: Bool {
        return scheme == "internal" && host == "local" && path == "/load/reader"
    }
}

/// Loads from any source by URL.
public struct ReaderContentLoader {
    @MainActor
    private static var inFlightGetContentTasks: [String: Task<(any ReaderContentProtocol)?, Error>] = [:]
    @RealmBackgroundActor
    private static var inFlightLoadAllTasks: [String: Task<[ContentReference], Error>] = [:]
    @RealmBackgroundActor
    private static var recentLoadAllCache: [String: (timestamp: Date, references: [ContentReference])] = [:]
    private static let loadAllCacheTTL: TimeInterval = 5

    public struct ContentReference {
        public let contentType: RealmSwift.Object.Type
        public let contentKey: String
        public let realmConfiguration: Realm.Configuration
        
        public init?(content: any ReaderContentProtocol) {
            guard let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type, let config = content.realm?.configuration else { return nil }
            self.contentType = contentType
            contentKey = content.compoundKey
            realmConfiguration = config
        }
        
        @RealmBackgroundActor
        public func resolveOnBackgroundActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            try await realm.asyncRefresh()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
        
        @MainActor
        public func resolveOnMainActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await Realm.open(configuration: realmConfiguration)
            try await realm.asyncRefresh()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
    }
    
    public static var bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var historyRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration

    public static func resetTransientCachesForTesting() async {
        await MainActor.run {
            inFlightGetContentTasks.removeAll()
        }
        await { @RealmBackgroundActor in
            inFlightLoadAllTasks.removeAll()
            recentLoadAllCache.removeAll()
        }()
    }

    @MainActor
    public static func hasLocallyRetrievableHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> Bool {
        let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
        return html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
 
    public static var unsavedHome: (any ReaderContentProtocol) {
//        return try await Self.load(url: URL(string: "about:blank")!, persist: false)!
        let historyRecord = HistoryRecord()
        historyRecord.url = URL(string: "about:blank")!
        historyRecord.updateCompoundKey()
        return historyRecord
    }
    
    @MainActor
    public static var home: (any ReaderContentProtocol) {
        get async throws {
            return try await Self.load(url: URL(string: "about:blank")!, persist: true)!
        }
    }
    
    public static func getContentURL(fromLoaderURL pageURL: URL) -> URL? {
        if pageURL.isReaderURLLoaderURL,
           let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           let readerURLItem = components.queryItems?.first(where: { $0.name == "reader-url" }),
           let readerURLValue = readerURLItem.value,
           let contentURL = URL(string: readerURLValue) {
            return contentURL
        }
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL) {
            return contentURL
        }
        return nil
    }

    private static func loadAllTaskKey(url: URL, skipContentFiles: Bool, skipFeedEntries: Bool) -> String {
        "\(url.absoluteString)|contentFiles:\(!skipContentFiles)|feedEntries:\(!skipFeedEntries)"
    }

    @RealmBackgroundActor
    private static func resolveContentReferences(
        _ references: [ContentReference]
    ) async throws -> [(any ReaderContentProtocol)] {
        var resolvedContents = [(any ReaderContentProtocol)]()
        resolvedContents.reserveCapacity(references.count)
        for reference in references {
            if let content = try await reference.resolveOnBackgroundActor() {
                resolvedContents.append(content)
            }
        }
        return resolvedContents
    }
    
    @RealmBackgroundActor
    public static func loadAll(url: URL, skipContentFiles: Bool = false, skipFeedEntries: Bool = false) async throws -> [(any ReaderContentProtocol)] {
        let taskKey = loadAllTaskKey(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries)
        if let cached = recentLoadAllCache[taskKey],
           Date().timeIntervalSince(cached.timestamp) < loadAllCacheTTL {
            return try await resolveContentReferences(cached.references)
        }
        if let existingTask = inFlightLoadAllTasks[taskKey] {
            if readerContentLoaderVerboseLoggingEnabled {
                logReaderLoad(
                    "stage=contentLoader.loadAll.coalesced url=\(url.absoluteString) taskKey=\(taskKey)"
                )
            }
            return try await resolveContentReferences(existingTask.value)
        }

        let task = Task<[ContentReference], Error> { @RealmBackgroundActor in
            let startedAt = Date()
            if readerContentLoaderVerboseLoggingEnabled {
                logReaderLoad(
                    "stage=contentLoader.loadAll.begin url=\(url.absoluteString) skipContentFiles=\(skipContentFiles) skipFeedEntries=\(skipFeedEntries)"
                )
            }
            try Task.checkCancellation()

            var contentFile: ContentFile?
            if !skipContentFiles {
                let contentFileStartedAt = Date()
                contentFile = try await ContentFile.get(forURL: url)
                let elapsed = Date().timeIntervalSince(contentFileStartedAt)
                if shouldLogLoadAllStep(found: contentFile != nil, elapsed: elapsed) {
                    logReaderLoad(
                        "stage=contentLoader.loadAll.contentFile elapsed=\(String(format: "%.3fs", elapsed)) found=\(contentFile != nil) url=\(url.absoluteString)"
                    )
                }
            }
            let historyStartedAt = Date()
            let history = try await HistoryRecord.get(forURL: url)
            let historyElapsed = Date().timeIntervalSince(historyStartedAt)
            if shouldLogLoadAllStep(found: history != nil, elapsed: historyElapsed) {
                logReaderLoad(
                    "stage=contentLoader.loadAll.history elapsed=\(String(format: "%.3fs", historyElapsed)) found=\(history != nil) url=\(url.absoluteString)"
                )
            }
            let bookmarkStartedAt = Date()
            let bookmark = try await Bookmark.get(forURL: url)
            let bookmarkElapsed = Date().timeIntervalSince(bookmarkStartedAt)
            if shouldLogLoadAllStep(found: bookmark != nil, elapsed: bookmarkElapsed) {
                logReaderLoad(
                    "stage=contentLoader.loadAll.bookmark elapsed=\(String(format: "%.3fs", bookmarkElapsed)) found=\(bookmark != nil) url=\(url.absoluteString)"
                )
            }

            var feed: FeedEntry?
            if !skipFeedEntries {
                let feedStartedAt = Date()
                let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
                let feeds = feedRealm.objects(FeedEntry.self)
                    .where { !$0.isDeleted }
                    .sorted(by: \.createdAt, ascending: false)

                if url.scheme == "https" {
                    feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@", url.absoluteString as CVarArg, url.settingScheme("http").absoluteString as CVarArg)).first
                } else if !url.isReaderFileURL {
                    feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
                }
                let feedElapsed = Date().timeIntervalSince(feedStartedAt)
                if shouldLogLoadAllStep(found: feed != nil, elapsed: feedElapsed) {
                    logReaderLoad(
                        "stage=contentLoader.loadAll.feed elapsed=\(String(format: "%.3fs", feedElapsed)) found=\(feed != nil) url=\(url.absoluteString)"
                    )
                }
            }

            let candidates: [any ReaderContentProtocol] = [contentFile, bookmark, history, feed].compactMap { $0 }
            let totalElapsed = Date().timeIntervalSince(startedAt)
            if shouldLogLoadAllSummary(candidateCount: candidates.count, elapsed: totalElapsed) {
                logReaderLoad(
                    "stage=contentLoader.loadAll.finish url=\(url.absoluteString) candidates=\(candidates.map { String(describing: type(of: $0)) }.joined(separator: ",")) count=\(candidates.count) elapsed=\(String(format: "%.3fs", totalElapsed))"
                )
            }
            return candidates.compactMap(ContentReference.init(content:))
        }

        inFlightLoadAllTasks[taskKey] = task
        defer { inFlightLoadAllTasks[taskKey] = nil }
        let references = try await task.value
        recentLoadAllCache[taskKey] = (timestamp: Date(), references: references)
        return try await resolveContentReferences(references)
    }

    @RealmBackgroundActor
    private static func storedContentReference(for url: URL) async throws -> ReaderContentLoader.ContentReference? {
        try Task.checkCancellation()
        guard !(url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/")) else {
            return nil
        }
        guard url.absoluteString != "about:blank" else {
            return nil
        }

        let candidates = try await loadAll(url: url)
        let match = candidates.max(by: {
            ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
        })
        guard let match else {
            return nil
        }
        return ReaderContentLoader.ContentReference(content: match)
    }

    @MainActor
    public static func lookupStoredContent(url: URL) async throws -> (any ReaderContentProtocol)? {
        let resolvedURL = getContentURL(fromLoaderURL: url) ?? url
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try await storedContentReference(for: resolvedURL)
        }()
        try Task.checkCancellation()
        return try await contentRef?.resolveOnMainActor()
    }

    @MainActor
    public static func getContent(
        forURL pageURL: URL,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.getContent"
    ) async throws -> (any ReaderContentProtocol)? {
        let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
        let taskKey = "\(resolvedURL.absoluteString)|history:\(countsAsHistoryVisit)"
        if let existingTask = inFlightGetContentTasks[taskKey] {
            logReaderLoad(
                "stage=contentLoader.getContent.coalesced pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) taskKey=\(taskKey) countsAsHistoryVisit=\(countsAsHistoryVisit) source=\(source)"
            )
            return try await existingTask.value
        }
        if countsAsHistoryVisit {
            let nonHistoryTaskKey = "\(resolvedURL.absoluteString)|history:false"
            if let existingTask = inFlightGetContentTasks[nonHistoryTaskKey] {
                logReaderLoad(
                    "stage=contentLoader.getContent.reuseNonHistoryTask pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) taskKey=\(nonHistoryTaskKey) countsAsHistoryVisit=\(countsAsHistoryVisit) source=\(source)"
                )
                let existingContent = try await existingTask.value
                if existingContent == nil || existingContent is HistoryRecord {
                    logReaderLoad(
                        "stage=contentLoader.getContent.reuseNonHistoryTask.accepted pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) contentURL=\(existingContent?.url.absoluteString ?? "nil") contentType=\(existingContent.map { String(describing: type(of: $0)) } ?? "nil") source=\(source)"
                    )
                    return existingContent
                }
                guard let existingContent else {
                    return nil
                }
                logReaderLoad(
                    "stage=contentLoader.getContent.reuseNonHistoryTask.rejected pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) contentURL=\(existingContent.url.absoluteString) contentType=\(String(describing: type(of: existingContent))) source=\(source)"
                )
            }
        } else {
            let historyTaskKey = "\(resolvedURL.absoluteString)|history:true"
            if let existingTask = inFlightGetContentTasks[historyTaskKey] {
                logReaderLoad(
                    "stage=contentLoader.getContent.reuseHistoryTask pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) taskKey=\(historyTaskKey) source=\(source)"
                )
                return try await existingTask.value
            }
        }

        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor in
            let startedAt = Date()
            logReaderLoad(
                "stage=contentLoader.getContent.begin pageURL=\(pageURL.absoluteString) resolvedURL=\(resolvedURL.absoluteString) countsAsHistoryVisit=\(countsAsHistoryVisit) isLoaderURL=\(pageURL.isReaderURLLoaderURL) source=\(source)"
            )
            if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL),
               let content = try await ReaderContentLoader.load(
                url: contentURL,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: "\(source).loaderRedirect"
               ) {
                try Task.checkCancellation()
                logReaderLoad(
                    "stage=contentLoader.getContent.loaderResolved pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt))) source=\(source)"
                )
                return content
            } else if let content = try await ReaderContentLoader.load(
                url: pageURL,
                persist: !pageURL.isNativeReaderView,
                countsAsHistoryVisit: true,
                source: "\(source).directLoad"
            ) {
                try Task.checkCancellation()
                logReaderLoad(
                    "stage=contentLoader.getContent.directResolved pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt))) source=\(source)"
                )
                return content
            }
            try Task.checkCancellation()
            logReaderLoad(
                "stage=contentLoader.getContent.missing pageURL=\(pageURL.absoluteString) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt))) source=\(source)"
            )
            return nil
        }

        inFlightGetContentTasks[taskKey] = task
        defer { inFlightGetContentTasks[taskKey] = nil }
        return try await task.value
    }

    /// Update all reader-content objects that share the given URL. The updater returns true if it mutated the object.
    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async throws {
        let objects = try await loadAll(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries)
        for case let object as (Object & ReaderContentProtocol) in objects {
            guard let realm = object.realm else { continue }
            try await realm.asyncWrite {
                if mutate(object) {
                    object.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    @MainActor
    public static func load(
        url: URL,
        persist: Bool = true,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.load"
    ) async throws -> (any ReaderContentProtocol)? {
        let startedAt = Date()
        logReaderLoad(
            "stage=contentLoader.load.begin url=\(url.absoluteString) persist=\(persist) countsAsHistoryVisit=\(countsAsHistoryVisit) source=\(source)"
        )
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try Task.checkCancellation()
            
            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                logReaderLoad("stage=contentLoader.load.skip reason=internalLoader url=\(url.absoluteString)")
                return nil
            } else if url.absoluteString == "about:blank" { //}&& !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.isDemoted = true
                historyRecord.updateCompoundKey()
                logReaderLoad("stage=contentLoader.load.aboutBlank url=\(url.absoluteString)")
                return ReaderContentLoader.ContentReference(content: historyRecord)
            }
            
            var match: (any ReaderContentProtocol)?
            let candidates = try await loadAll(url: url)
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                logReaderLoad(
                    "stage=contentLoader.load.addHistoryVisit url=\(url.absoluteString) contentType=\(String(describing: type(of: nonHistoryMatch))) key=\(nonHistoryMatch.compoundKey)"
                )
                match = try await nonHistoryMatch.addHistoryRecord(realmConfiguration: historyRealmConfiguration, pageURL: url)
            } else if match == nil, !url.isEBookURL {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                //        historyRecord.isReaderModeByDefault
                historyRecord.updateCompoundKey()
                if persist {
                    let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
//                    await historyRealm.asyncRefresh()
                    try await historyRealm.asyncWrite {
                        historyRealm.add(historyRecord, update: .modified)
                    }
                }
                match = historyRecord
                logReaderLoad(
                    "stage=contentLoader.load.createdHistory url=\(url.absoluteString) persist=\(persist)"
                )
            }
            
            try Task.checkCancellation()
            if persist, let match = match, url.isReaderFileURL, url.contains(.plainText), let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
            } else if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault, let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            guard let match else { return nil }
            
            if let historyRecord = match as? HistoryRecord {
                try await historyRecord.refreshDemotedStatus()
            }

            return ReaderContentLoader.ContentReference(content: match)
        }()
        try Task.checkCancellation()
        let content = try await contentRef?.resolveOnMainActor()
        if let content {
            logReaderLoad(
                "stage=contentLoader.load.finish url=\(url.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey) readerDefault=\(content.isReaderModeByDefault) hasHTML=\(content.hasHTML) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt))) source=\(source)"
            )
        } else {
            logReaderLoad("stage=contentLoader.load.finish url=\(url.absoluteString) content=nil elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt))) source=\(source)")
        }
        return content
    }
    
    @MainActor
    public static func load(urlString: String, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return try await load(
            url: url,
            countsAsHistoryVisit: countsAsHistoryVisit,
            source: "ReaderContentLoader.load.urlString"
        )
    }
    
    @MainActor
    public static func load(
        html: String,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
            let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
            
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let generatedTitle = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""
            logSnippetEvent(
                "loadHTML.begin",
                "normalizedBytes=\(normalizedHTML.utf8.count)",
                "generatedTitle=\(generatedTitle.truncate(80))",
                "allowContentMatch=\(allowContentMatch)"
            )

            if allowContentMatch {
                let bookmark = bookmarkRealm.objects(Bookmark.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let history = historyRealm.objects(HistoryRecord.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let feed = feedRealm.objects(FeedEntry.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let candidates: [any ReaderContentProtocol] = [bookmark, history, feed].compactMap { $0 }

                if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
                    logSnippetEvent(
                        "loadHTML.match",
                        "url=\(match.url.absoluteString)",
                        "title=\(match.title.truncate(80))",
                        "createdAt=\(match.createdAt.timeIntervalSince1970)"
                    )
                    return ReaderContentLoader.ContentReference(content: match)
                }
            } else {
                logSnippetEvent("loadHTML.matchSkipped", "reason=createNewSnippet")
            }
            
            let historyRecord = HistoryRecord()
            historyRecord.publicationDate = Date()
            historyRecord.content = data
            historyRecord.title = generatedTitle
            historyRecord.isTitlePrefixOfContent = !generatedTitle.isEmpty
            // isReaderModeByDefault used to be commented out... why?
            historyRecord.isReaderModeByDefault = true
            historyRecord.isDemoted = false
            historyRecord.updateCompoundKey()
            historyRecord.rssContainsFullContent = true
            historyRecord.url = snippetURL(key: historyRecord.compoundKey) ?? historyRecord.url
//            await historyRealm.asyncRefresh()
            try await historyRealm.asyncWrite {
                historyRealm.add(historyRecord, update: .modified)
            }

            logSnippetEvent(
                "loadHTML.createdSnippet",
                "url=\(historyRecord.url.absoluteString)",
                "title=\(historyRecord.title.truncate(80))",
                "isTitlePrefixOfContent=\(historyRecord.isTitlePrefixOfContent)",
                "contentBytes=\(historyRecord.content?.count ?? 0)"
            )
            
            return ReaderContentLoader.ContentReference(content: historyRecord)
        }()
        
        let resolved = try await contentRef?.resolveOnMainActor()
        if let resolved {
            logSnippetEvent(
                "loadHTML.resolved",
                "url=\(resolved.url.absoluteString)",
                "title=\(resolved.title.truncate(80))",
                "isSnippetURL=\(resolved.url.isSnippetURL)"
            )
        } else {
            logSnippetEvent("loadHTML.resolved", "content=<nil>")
        }
        return resolved
    }
    
    /// Returns a URL to load for the given content into a Reader instance. The URL is either a resource (like a web location),
    /// or an internal "local" URL for loading HTML content in Reader Mode.
    @MainActor
    public static func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> URL? {
        let startedAt = Date()
        let contentURL = content.url
        logReaderLoad(
            "stage=contentLoader.loadContent.begin contentURL=\(contentURL.absoluteString) contentType=\(String(describing: type(of: content))) readerDefault=\(content.isReaderModeByDefault) readerAvailable=\(content.isReaderModeAvailable) hasHTML=\(content.hasHTML)"
        )
        let htmlProbeStartedAt = Date()
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )
        logReaderLoad(
            "stage=contentLoader.loadContent.htmlProbe contentURL=\(contentURL.absoluteString) hasLocallyRetrievableHTML=\(contentHasLocallyRetrievableHTML) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(htmlProbeStartedAt)))"
        )

        if contentURL.isSnippetURL {
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=snippetLoader elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
                )
                return loaderURL
            }
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=snippetDirect elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
            )
            return content.url
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=contentReaderDefault elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
                )
                return loaderURL
            }

            if let matchingContent = try await lookupStoredContent(url: contentURL),
               matchingContent.isReaderModeByDefault,
               (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
               )) == true,
               let matchingURL = readerLoaderURL(for: matchingContent.url) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(matchingURL.absoluteString) reason=matchingContentReaderDefault matchingContentURL=\(matchingContent.url.absoluteString) elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
                )
                return matchingURL
            }
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=httpDirect elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
            )
            return content.url
        }

        if contentURL.isReaderFileURL,
           contentHasLocallyRetrievableHTML,
           let loaderURL = readerLoaderURL(for: contentURL) {
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=fileLoader elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
            )
            return loaderURL
        }
        
        logReaderLoad(
            "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=directFallback elapsed=\(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))"
        )
        return content.url
    }

    static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        return (
            ((doc.body()?.children().isEmpty()) ?? true)
            || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1) )
    }
    
    public static func textToHTMLDoc(_ text: String) throws -> SwiftSoup.Document {
        let html = textToHTML(text)
        return try SwiftSoup.parse(html)
    }

    private static func rawPlainTextToHTML(_ text: String) -> String {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs = [String]()
        var currentParagraphLines = [String]()

        let flushParagraph = {
            guard !currentParagraphLines.isEmpty else { return }
            paragraphs.append("<p>\(currentParagraphLines.joined(separator: "<br>"))</p>")
            currentParagraphLines.removeAll()
        }

        for line in normalizedText.components(separatedBy: "\n") {
            if line.isEmpty {
                flushParagraph()
            } else {
                currentParagraphLines.append(line.escapeHtml())
            }
        }
        flushParagraph()

        return "<html><body>\(paragraphs.joined())</body></html>"
    }
    
    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        var convertedText = text
        if forceRaw {
            convertedText = rawPlainTextToHTML(text)
        } else if let doc = try? SwiftSoup.parse(text) {
            if docIsPlainText(doc: doc) {
                convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
            }
        } else {
            convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
        }
        return convertedText
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func readerLoaderURL(for contentURL: URL) -> URL? {
        guard let encodedURL = contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            logReaderLoad("stage=contentLoader.readerLoaderURL.failed contentURL=\(contentURL.absoluteString)")
            return nil
        }
        return URL(string: "internal://local/load/reader?reader-url=\(encodedURL)")
    }
    
    @MainActor
    public static func load(
        text: String,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let html = snippetHTML(fromRawText: text)
        return try await load(html: html, allowContentMatch: allowContentMatch)
    }
    
    @MainActor
    public static func loadPasteboard(
        bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        historyRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        var match: (any ReaderContentProtocol)?
        
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            logSnippetEvent(
                "loadPasteboard.url",
                "url=\(url.absoluteString)"
            )
            match = try await load(url: url, countsAsHistoryVisit: true)
        } else if let payload = preferredPasteboardPayload(html: html, text: text) {
            let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
            logSnippetEvent(
                "loadPasteboard.payload",
                "explicitHTML=\(payload.explicitHTML)",
                "format=\(normalized.format)",
                "textPreview=\(payload.text.truncate(80))",
                "allowContentMatch=\(allowContentMatch)"
            )
            match = try await load(html: normalized.html, allowContentMatch: allowContentMatch)
        }

        if let match {
            logSnippetEvent(
                "loadPasteboard.result",
                "url=\(match.url.absoluteString)",
                "isSnippetURL=\(match.url.isSnippetURL)",
                "title=\(match.title.truncate(80))"
            )
        } else {
            logSnippetEvent("loadPasteboard.result", "match=<nil>")
        }
        
        if let match, let realmConfiguration = match.realm?.configuration {
            if match.url.isSnippetURL {
                let type = type(of: match)
                let pk = match.primaryKeyValue
                guard let url = URL(string: match.url.absoluteString) else { return nil }
                try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration) 
                    if let pk = pk, let content = realm.object(ofType: type, forPrimaryKey: pk), let content = content as? (any ReaderContentProtocol) {
                        let url = snippetURL(key: content.compoundKey) ?? content.url
//                        await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            content.isFromClipboard = true
                            content.rssContainsFullContent = true
                            content.isReaderModeByDefault = true
                            content.url = url
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }()
                return match.realm?.object(ofType: type, forPrimaryKey: pk) as? (any ReaderContentProtocol)? ?? nil
            } else {
                return match
            }
        }
        return nil
    }

    public static func snippetHTML(fromRawText text: String) -> String {
        normalizeSnippetSourceHTML(textToHTML(text, forceRaw: true))
    }

    public static func snippetHTMLFromPasteText(_ text: String) -> String {
        let normalized = normalizeIngestedText(text, explicitHTML: false, source: .paste)
        return normalizeSnippetSourceHTML(normalized.html)
    }

    public static func snippetHTML(fromHTML html: String) -> String {
        normalizeSnippetSourceHTML(html)
    }

    public static let snippetReaderTitleSuppressionBodyClass = "manabi-hide-redundant-snippet-reader-title"

    public static func resolvedDisplayTitle(
        _ rawTitle: String,
        needsClipboardIndicator: Bool,
        addClipboardIndicator: Bool = false
    ) -> String {
        var displayTitle = rawTitle.removingClipboardIndicatorIfNeeded(needsClipboardIndicator)
        displayTitle = displayTitle.removingHTMLTags() ?? displayTitle
        if displayTitle.isEmpty {
            displayTitle = "Untitled"
        }
        if addClipboardIndicator {
            return "📎 " + displayTitle
        }
        return displayTitle
    }

    public static func resolvedSnippetLocationBarTitle(
        title: String,
        createdAt: Date,
        needsClipboardIndicator: Bool,
        isTitlePrefixOfContent: Bool
    ) -> String {
        let fallbackTitle = "Snippet — \(createdAt.readerSnippetChromeDateString)"
        if isTitlePrefixOfContent {
            return fallbackTitle
        }
        let cleanedTitle = resolvedDisplayTitle(
            title,
            needsClipboardIndicator: needsClipboardIndicator
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle
    }

    private static func snippetAutoTitleCompactComparisonValue(_ raw: String?) -> String? {
        canonicalSnippetAutoTitleComparisonValue(raw)?
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func canonicalSnippetAutoTitleComparisonValue(_ raw: String?) -> String? {
        normalizedSnippetAutoTitle(raw)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines))
    }

    public static func normalizedSnippetAutoTitle(_ raw: String?) -> String? {
        let rawValue = raw ?? ""
        let sanitized = rawValue.removingHTMLTags() ?? rawValue
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.truncate(36)
    }

    public static func generatedSnippetTitle(fromSourceHTML html: String) -> String? {
        titleFromReadabilityHTML(normalizeSnippetSourceHTML(html))
            .flatMap { normalizedSnippetAutoTitle($0) }
    }

    public static func snippetTitleMatchesGeneratedPrefix(
        _ title: String,
        sourceHTML: String?
    ) -> Bool {
        let normalizedTitle = normalizedSnippetAutoTitle(title)
        let generatedTitle = sourceHTML.flatMap { generatedSnippetTitle(fromSourceHTML: $0) }
        let canonicalTitle = canonicalSnippetAutoTitleComparisonValue(title)
        let canonicalGeneratedTitle = canonicalSnippetAutoTitleComparisonValue(generatedTitle)
        let compactTitle = snippetAutoTitleCompactComparisonValue(title)
        let compactGeneratedTitle = snippetAutoTitleCompactComparisonValue(generatedTitle)
        let matches = {
            let canonicalMatch = {
                guard let canonicalTitle, let canonicalGeneratedTitle else { return false }
                return canonicalTitle == canonicalGeneratedTitle
                || canonicalGeneratedTitle.hasPrefix(canonicalTitle)
                || canonicalTitle.hasPrefix(canonicalGeneratedTitle)
            }()
            let compactMatch = {
                guard let compactTitle, let compactGeneratedTitle else { return false }
                return compactTitle == compactGeneratedTitle
                    || compactGeneratedTitle.hasPrefix(compactTitle)
                    || compactTitle.hasPrefix(compactGeneratedTitle)
            }()
            return canonicalMatch || compactMatch
        }()
        debugPrint(
            "# SNIPPETTITLE matchCheck",
            "title=\(title)",
            "normalizedTitle=\(normalizedTitle ?? "<nil>")",
            "generatedTitle=\(generatedTitle ?? "<nil>")",
            "canonicalTitle=\(canonicalTitle ?? "<nil>")",
            "canonicalGeneratedTitle=\(canonicalGeneratedTitle ?? "<nil>")",
            "compactTitle=\(compactTitle ?? "<nil>")",
            "compactGeneratedTitle=\(compactGeneratedTitle ?? "<nil>")",
            "hasSourceHTML=\(sourceHTML != nil)",
            "matches=\(matches)"
        )
        return matches
    }

    private static func resolvedSnippetTitleAfterHTMLUpdate(
        currentTitle: String,
        currentHTML: String?,
        updatedHTML: String,
        requestedTitle: String? = nil,
        currentIsTitlePrefixOfContent: Bool? = nil
    ) -> (title: String, isTitlePrefixOfContent: Bool) {
        let desiredTitle = requestedTitle ?? currentTitle
        let shouldAutoRetitle =
            desiredTitle == currentTitle &&
            (currentIsTitlePrefixOfContent
                ?? snippetTitleMatchesGeneratedPrefix(currentTitle, sourceHTML: currentHTML))
        let resolvedTitle: String
        if shouldAutoRetitle,
           let generatedTitle = generatedSnippetTitle(fromSourceHTML: updatedHTML) {
            resolvedTitle = generatedTitle
            debugPrint(
                "# SNIPPETTITLE autoRetitle",
                "currentTitle=\(currentTitle)",
                "requestedTitle=\(requestedTitle ?? "<nil>")",
                "resolvedTitle=\(generatedTitle)"
            )
        } else {
            resolvedTitle = desiredTitle
        }
        return (
            resolvedTitle,
            snippetTitleMatchesGeneratedPrefix(resolvedTitle, sourceHTML: updatedHTML)
        )
    }

    @MainActor
    public static func snippetEditorHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = .shared
    ) async throws -> String {
        if let html = try await content.htmlToDisplay(readerFileManager: readerFileManager),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeSnippetSourceHTML(html)
        }
        return normalizeSnippetSourceHTML("<html><body></body></html>")
    }

    public static func loadPasteboardSnippetHTML() -> String? {
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif

        guard let payload = preferredPasteboardPayload(html: html, text: text) else {
            logSnippetEvent("loadPasteboardSnippetHTML", "payload=<nil>")
            return nil
        }
        let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
        logSnippetEvent(
            "loadPasteboardSnippetHTML",
            "explicitHTML=\(payload.explicitHTML)",
            "format=\(normalized.format)",
            "textPreview=\(payload.text.truncate(80))"
        )
        return normalizeSnippetSourceHTML(normalized.html)
    }

#if DEBUG
    public static let debugSnippetFallbackRawText = """
# Updated via Snippet Helper

This snippet loads when the pasteboard is empty in a debug build.

- First line borrowed from snippet loader tests.
- Second line is plain Markdown for quick UI checks.
- Third line makes the preview a little less bare.
"""
#endif

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        to content: any ReaderContentProtocol
    ) async throws -> (any ReaderContentProtocol)? {
        guard content.url.isSnippetURL else {
            return nil
        }

        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
        let contentURL = content.url
        logSnippetEvent(
            "appendSnippetHTML.begin",
            "contentURL=\(contentURL.absoluteString)",
            "incomingBytes=\(normalizedAppendedHTML.utf8.count)"
        )

        try await { @RealmBackgroundActor in
            try await updateContent(url: contentURL) { object in
                let currentHTML = object.html
                guard let mergedHTML = try? appendSnippetHTML(
                    normalizedAppendedHTML,
                    toExistingHTML: currentHTML
                ) else {
                    return false
                }

                let normalizedCurrentHTML = snippetHTML(fromHTML: currentHTML ?? "<html><body></body></html>")
                let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: currentHTML,
                    updatedHTML: mergedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if normalizedCurrentHTML != normalizedMergedHTML {
                    object.html = mergedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }
                if object.rssContainsFullContent == false {
                    object.rssContainsFullContent = true
                    objectDidChange = true
                }
                if object.isReaderModeByDefault == false {
                    object.isReaderModeByDefault = true
                    objectDidChange = true
                }

                logSnippetEvent(
                    "appendSnippetHTML.merge",
                    "contentURL=\(contentURL.absoluteString)",
                    "currentBytes=\((currentHTML ?? "").utf8.count)",
                    "mergedBytes=\(mergedHTML.utf8.count)",
                    "didChange=\(objectDidChange)",
                    "title=\(object.title.truncate(80))"
                )

                return objectDidChange
            }
        }()

        logSnippetEvent(
            "appendSnippetHTML.reload",
            "contentURL=\(contentURL.absoluteString)",
            "persist=false",
            "countsAsHistoryVisit=false"
        )
        return try await load(
            url: contentURL,
            persist: false,
            countsAsHistoryVisit: false,
            source: "ReaderContentLoader.appendSnippetHTML.reload"
        )
    }

    @MainActor
    public static func updateSnippetHTML(
        contentURL: URL,
        html: String
    ) async throws -> Bool {
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let existingHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: object.html,
                    updatedHTML: normalizedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if existingHTML != normalizedHTML {
                    object.html = normalizedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }

                if objectDidChange {
                    didChange = true
                }
                return objectDidChange
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String
    ) async throws -> Bool {
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let currentHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let currentTitle = object.title
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: currentTitle,
                    currentHTML: object.html,
                    updatedHTML: normalizedHTML,
                    requestedTitle: title,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if currentTitle != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }
                if currentHTML != normalizedHTML {
                    object.html = normalizedHTML
                    objectDidChange = true
                }

                if objectDidChange {
                    didChange = true
                }
                return objectDidChange
            }
            return didChange
        }()
    }

    static func preferredPasteboardPayload(html: String?, text: String?) -> (text: String, explicitHTML: Bool)? {
        func normalizedClipboardText(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let stripped = (raw.removingHTMLTags() ?? raw)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            return stripped
        }

        let normalizedHTMLText = normalizedClipboardText(html)
        let normalizedPlainText = normalizedClipboardText(text)

        if let normalizedHTMLText, let normalizedPlainText, normalizedHTMLText == normalizedPlainText {
            logSnippetEvent(
                "preferredPasteboardPayload",
                "selected=plainText",
                "reason=htmlMatchesPlainText",
                "plainPreview=\(normalizedPlainText.truncate(80))"
            )
            return (normalizedPlainText, false)
        }

        if let html {
            if normalizeIngestedText(html, explicitHTML: false, source: .paste).format == .html {
                logSnippetEvent(
                    "preferredPasteboardPayload",
                    "selected=html",
                    "reason=looksLikeHTML",
                    "htmlPreview=\(html.truncate(80))"
                )
                return (html, true)
            }
        }
        if let text {
            logSnippetEvent(
                "preferredPasteboardPayload",
                "selected=plainText",
                "reason=textFallback",
                "plainPreview=\(text.truncate(80))"
            )
            return (text, false)
        }
        if let html {
            logSnippetEvent(
                "preferredPasteboardPayload",
                "selected=htmlAsText",
                "reason=htmlOnlyNonExplicit",
                "htmlPreview=\(html.truncate(80))"
            )
            return (html, false)
        }
        logSnippetEvent("preferredPasteboardPayload", "selected=<nil>")
        return nil
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        if let text = text {
            try await _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            try await _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        let html = Self.textToHTML(text)
        try await _ = Bookmark.add(url: url, title: title ?? "", html: html, isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
    }

    private static let snippetWrapperClass = "manabi-snippet"

    static func normalizeSnippetSourceHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html),
              let body = doc.body() else {
            return html
        }

        let bodyHTML = (try? body.html())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bodyHTML.isEmpty else {
            return html
        }

        let bodyChildren = body.children()
        let isAlreadyWrapped = !bodyChildren.isEmpty && bodyChildren.allSatisfy {
            $0.hasClass(snippetWrapperClass)
        }

        guard !isAlreadyWrapped else {
            return (try? doc.outerHtml()) ?? html
        }

        try? body.html(#"<div class="\#(snippetWrapperClass)">\#(bodyHTML)</div>"#)
        return (try? doc.outerHtml()) ?? html
    }

    private static func appendSnippetHTML(_ appendedHTML: String, toExistingHTML existingHTML: String?) throws -> String {
        let baseHTML = normalizeSnippetSourceHTML(existingHTML ?? "<html><body></body></html>")
        let baseDoc = try SwiftSoup.parse(baseHTML)
        let appendedDoc = try SwiftSoup.parse(normalizeSnippetSourceHTML(appendedHTML))

        let existingBody = try baseDoc.body()
        let appendedBody = try appendedDoc.body()
        let appendedBodyHTML = try appendedBody?.html().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if appendedBodyHTML.isEmpty {
            return try baseDoc.outerHtml()
        }

        try existingBody?.append(appendedBodyHTML)
        return try baseDoc.outerHtml()
    }
}

/// Forked from: https://github.com/objecthub/swift-markdownkit/issues/6
open class PasteboardHTMLGenerator: HtmlGenerator {
    override open func generate(text: MarkdownKit.Text) -> String {
        var res = ""
        for (idx, fragment) in text.enumerated() {
            if (idx + 1) < text.count {
                let next = text[idx + 1]
                switch (fragment as TextFragment, next as TextFragment) {
                case (.softLineBreak, .text(let text)):
                    if text.hasPrefix("　") || text.hasPrefix("    ") {
                        res += "<br/><br/>" // TODO: Morph to paragraph
                        continue
                    }
                case (.softLineBreak, .softLineBreak):
                    res += "<br/><br/>" // TODO: Morph to paragraph
                    continue
                default:
                    break
                }
            }
            
            res += generate(textFragment: fragment)
        }
        return res
    }
    
//    override open func generate(textFragment fragment: TextFragment) -> String {
//        switch fragment {
//        case .softLineBreak:
//            return "<br/>"
//        default:
//            return super.generate(textFragment: fragment)
//        }
//    }
}

fileprivate extension URL {
    var contentType: UTType {
        return UTType(filenameExtension: self.pathExtension) ?? .data
    }
}
