import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import WebKit

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum CustomSchemeHandlerError: Error {
        case notFound
        case missingKey
        case missingHTML
    }

    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let taskQueue = DispatchQueue(label: "InternalURLSchemeHandler.tasks")
    private let snippetPath = "/snippet"

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }

        if url.path == snippetPath {
            handleSnippetRequest(url: url, task: urlSchemeTask)
            return
        }

        // Default: return empty body; reader mode will inject content later.
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        taskQueue.sync {
            pendingTasks[identifier]?.cancel()
            pendingTasks.removeValue(forKey: identifier)
        }
    }

    private func handleSnippetRequest(url: URL, task urlSchemeTask: WKURLSchemeTask) {
        guard let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else {
            debugPrint("# READER snippetScheme.error", "reason=missingKey", "url=\(url.absoluteString)")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.missingKey)
            return
        }

        debugPrint("# READER snippetScheme.start", "key=\(key)", "url=\(url.absoluteString)")

        let identifier = ObjectIdentifier(urlSchemeTask)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                self?.taskQueue.async {
                    self?.pendingTasks.removeValue(forKey: identifier)
                }
            }

            do {
                let data = try await Self.snippetHTMLData(forKey: key)
                if let htmlString = String(data: data, encoding: .utf8) {
                    let hasReaderContent = htmlString.contains("id=\"reader-content\"")
                    let hasReadabilityMode = htmlString.contains("readability-mode")
                    let loggedHTML = fullSnippetLogString(htmlString)
                    debugPrint(
                        "# READER snippetScheme.content",
                        "key=\(key)",
                        "hasReaderContent=\(hasReaderContent)",
                        "hasReadabilityMode=\(hasReadabilityMode)",
                        "html=\(loggedHTML)"
                    )
                }
                try Task.checkCancellation()
                let response = URLResponse(
                    url: url,
                    mimeType: "text/html",
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )

                await MainActor.run {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
                debugPrint("# READER snippetScheme.finish", "key=\(key)", "bytes=\(data.count)")
            } catch is CancellationError {
                debugPrint("# READER snippetScheme.cancelled", "key=\(key)")
            } catch {
                debugPrint("# READER snippetScheme.error", "reason=\(error)", "key=\(key)")
                await MainActor.run {
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        taskQueue.async { [weak self] in
            self?.pendingTasks[identifier] = task
        }
    }

    @RealmBackgroundActor
    private static func snippetHTMLData(forKey key: String) async throws -> Data {
        if let data = try await htmlDataFromHistory(forKey: key) {
            return data
        }
        if let data = try await htmlDataFromBookmark(forKey: key) {
            return data
        }
        if let snippetURL = ReaderContentLoader.snippetURL(key: key),
           let data = try await htmlDataFromBookmarkURL(snippetURL) {
            return data
        }
        debugPrint("# READER snippetScheme.error", "reason=noHTML", "key=\(key)")
        throw CustomSchemeHandlerError.missingHTML
    }

    @RealmBackgroundActor
    private static func htmlDataFromHistory(forKey key: String) async throws -> Data? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
        guard let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: key), !record.isDeleted else {
            debugPrint("# READER snippetScheme.history.missingRecord", "key=\(key)")
            return nil
        }
        if let resolution = SnippetHTMLResolver.resolve(
            legacyHTMLContent: record.htmlContent,
            compressedContent: record.content
        ) {
            logSnippetDecodedHTML("history", key: key, html: resolution.html)
            debugPrint(
                "# READER snippetScheme.history.hit",
                "key=\(key)",
                "htmlBytes=\(resolution.htmlByteCount)",
                "compressedBytes=\(resolution.compressedByteCount)"
            )
            return resolution.data
        }
        if let bookmarkID = record.bookmarkID,
           let data = try await htmlDataFromBookmark(forKey: bookmarkID) {
            debugPrint("# READER snippetScheme.history.fallbackBookmark", "key=\(key)", "bookmarkID=\(bookmarkID)")
            return data
        }
        debugPrint("# READER snippetScheme.history.noHTML", "key=\(key)")
        return nil
    }

    @RealmBackgroundActor
    private static func htmlDataFromBookmark(forKey key: String) async throws -> Data? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
        guard let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: key), !bookmark.isDeleted else {
            debugPrint("# READER snippetScheme.bookmark.missingRecord", "key=\(key)")
            return nil
        }
        guard let resolution = SnippetHTMLResolver.resolve(
            legacyHTMLContent: bookmark.htmlContent,
            compressedContent: bookmark.content
        ) else {
            debugPrint("# READER snippetScheme.bookmark.noHTML", "key=\(key)")
            return nil
        }
        logSnippetDecodedHTML("bookmark", key: key, html: resolution.html)
        debugPrint(
            "# READER snippetScheme.bookmark.hit",
            "key=\(key)",
            "htmlBytes=\(resolution.htmlByteCount)",
            "compressedBytes=\(resolution.compressedByteCount)"
        )
        return resolution.data
    }

    @RealmBackgroundActor
    private static func htmlDataFromBookmarkURL(_ url: URL) async throws -> Data? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
        guard let bookmark = realm.objects(Bookmark.self)
            .filter(NSPredicate(format: "url == %@ AND isDeleted == false", url.absoluteString))
            .sorted(byKeyPath: "createdAt", ascending: false)
            .first else {
            debugPrint("# READER snippetScheme.bookmarkURL.missingRecord", "url=\(url.absoluteString)")
            return nil
        }
        guard let resolution = SnippetHTMLResolver.resolve(
            legacyHTMLContent: bookmark.htmlContent,
            compressedContent: bookmark.content
        ) else {
            debugPrint("# READER snippetScheme.bookmarkURL.noHTML", "key=\(bookmark.compoundKey)")
            return nil
        }
        logSnippetDecodedHTML("bookmarkURL", key: bookmark.compoundKey, html: resolution.html)
        debugPrint(
            "# READER snippetScheme.bookmarkURL.hit",
            "key=\(bookmark.compoundKey)",
            "htmlBytes=\(resolution.htmlByteCount)",
            "compressedBytes=\(resolution.compressedByteCount)"
        )
        return resolution.data
    }
}

internal struct SnippetHTMLResolution {
    let html: String
    let data: Data
    let compressedByteCount: Int

    var htmlByteCount: Int { data.count }
}

internal enum SnippetHTMLResolver {
    static func resolve(legacyHTMLContent: String?, compressedContent: Data?) -> SnippetHTMLResolution? {
        let legacyBytes = legacyHTMLContent?.utf8.count ?? 0
        let compressedBytes = compressedContent?.count ?? 0
        debugPrint(
            "# READER snippetResolver.input",
            "legacyBytes=\(legacyBytes)",
            "compressedBytes=\(compressedBytes)"
        )
        guard let htmlString = Bookmark.contentToHTML(
            legacyHTMLContent: legacyHTMLContent,
            content: compressedContent
        ) else {
            return nil
        }
        let data = Data(htmlString.utf8)
        let preview = summarizeHTML(htmlString)
        debugPrint(
            "# READER snippetResolver.output",
            "htmlBytes=\(data.count)",
            "preview=\(preview)",
            "html=\(fullSnippetLogString(htmlString))"
        )
        return SnippetHTMLResolution(
            html: htmlString,
            data: data,
            compressedByteCount: compressedContent?.count ?? 0
        )
    }

    private static func summarizeHTML(_ html: String, maxLength: Int = 360) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<idx]) + "…"
    }
}

private func fullSnippetLogString(_ html: String, maxLength: Int = 4096) -> String {
    if html.count <= maxLength {
        return html
    }
    let idx = html.index(html.startIndex, offsetBy: maxLength)
    return String(html[..<idx]) + "…"
}

private func logSnippetDecodedHTML(_ source: String, key: String, html: String) {
    debugPrint(
        "# READER snippetHTML.decoded",
        "source=\(source)",
        "key=\(key)",
        "html=\(fullSnippetLogString(html))"
    )
}
