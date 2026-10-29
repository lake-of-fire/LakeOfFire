import Foundation
import SwiftSoup
import LakeOfFireCore

struct ReaderAssetResponse: Sendable {
    let data: Data
    let mimeType: String
}

func readerResourceHasSameOrigin(_ first: URL, _ second: URL) -> Bool {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
    return first.isHTTP && second.isHTTP
        && first.scheme?.lowercased() == second.scheme?.lowercased()
        && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
}

/// Unknown/empty policies inherit rather than silently changing request context.
func normalizedReaderReferrerPolicy(_ raw: String?) -> String? {
    let policy = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch policy {
    case "never": return "no-referrer"
    case "always": return "unsafe-url"
    case "default": return "no-referrer-when-downgrade"
    case "origin-when-crossorigin": return "origin-when-cross-origin"
    case "no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin", "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url": return policy
    default: return nil
    }
}

func readerDocumentReferrerPolicy(in document: SwiftSoup.Document) throws -> String? {
    var policy: String?
    for meta in try document.select("meta[name][content]") where try meta.attr("name").lowercased() == "referrer" {
        if let value = normalizedReaderReferrerPolicy(try meta.attr("content")) { policy = value }
    }
    return policy
}

enum ReaderAssetRequestFailure: Error {
    case httpStatus(Int)
}

/// Network delivery is selected before WebKit starts a resource. A bounded
/// native request can supply publisher context without changing article origin.
actor ReaderAssetService {
    static let shared = ReaderAssetService()
    private let protocolClasses: [AnyClass]?
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    func load(entry: ReaderDocumentResourceRegistry.Entry, cookies: [HTTPCookie]) async throws -> ReaderAssetResponse {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        switch entry.resource { case .image, .caption, .svgSymbol: break; default: throw URLError(.unsupportedURL) }
        guard let url = entry.resource.remoteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let trace = ReaderLoadTrace.$operationID.withValue(entry.generation) { ReaderLoadTrace.begin("reader.assetRequest") }
        do {
            let request = ReaderAssetRequest(entry: entry, cookies: cookies, protocolClasses: protocolClasses)
            let response = try await request.perform()
            trace?.end("component=\(entry.diagnosticID) status=loaded bytes=\(response.data.count)")
            return response
        } catch {
            let httpDetail: String
            if let failure = error as? ReaderAssetRequestFailure, case .httpStatus(let status) = failure { httpDetail = " http_status=\(status)" }
            else { httpDetail = "" }
            trace?.end("component=\(entry.diagnosticID) " + (error is CancellationError || (error as? URLError)?.code == .cancelled ? "status=cancelled" : "status=failed") + httpDetail)
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < 6 { active += 1; return }
        guard waiting.count < 128 else { throw URLError(.resourceUnavailable) }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() }
    }
}

/// URLSession's data(for:) buffers an unrestricted body. This delegate enforces
/// the limit while bytes arrive, including chunked and dishonest length replies.
private final class ReaderAssetRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let entry: ReaderDocumentResourceRegistry.Entry
    private let cookies: [HTTPCookie]
    private let protocolClasses: [AnyClass]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ReaderAssetResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var data = Data()
    private var mimeType = ""
    private var responseFailure: Error?
    private let maximumBytes = 16 * 1_024 * 1_024

    init(entry: ReaderDocumentResourceRegistry.Entry, cookies: [HTTPCookie], protocolClasses: [AnyClass]?) {
        self.entry = entry
        self.cookies = entry.allowsCookies ? cookies : []
        self.protocolClasses = protocolClasses
    }

    func perform() async throws -> ReaderAssetResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled, let url = entry.resource.remoteURL else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let config = URLSessionConfiguration.default
                if let protocolClasses { config.protocolClasses = protocolClasses }
                config.timeoutIntervalForRequest = 20
                config.timeoutIntervalForResource = 30
                // WebKit's domain-scoped cookies are copied to each admitted
                // request/redirect. Never mutate a shared cookie jar.
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.requestCachePolicy = .useProtocolCachePolicy
                config.urlCache = entry.cookieContext.cache(allowsCookies: entry.allowsCookies)
                if !entry.allowsCookies || !entry.cookieContext.permitsSharedCredentials { config.urlCredentialStorage = nil }
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
                self.session = session
                var request = Self.request(url: url, source: entry.sourceURL, cookies: cookies, referrerPolicy: entry.referrerPolicy)
                request.setValue(entry.cookieContext.userAgent, forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    static func request(url: URL, source: URL, cookies: [HTTPCookie], referrerPolicy: String?) -> URLRequest {
        var request = URLRequest(url: url)
        var referrer = URLComponents(url: source, resolvingAgainstBaseURL: false)
        referrer?.user = nil; referrer?.password = nil; referrer?.fragment = nil
        let sameOrigin = readerResourceHasSameOrigin(source, url)
        let policy = normalizedReaderReferrerPolicy(referrerPolicy) ?? "strict-origin-when-cross-origin"
        let fullURL = policy == "unsafe-url" || policy == "no-referrer-when-downgrade" || sameOrigin && !["origin", "strict-origin"].contains(policy)
        if !fullURL { referrer?.path = "/"; referrer?.query = nil }
        let downgrade = source.scheme == "https" && url.scheme == "http"
        if source.isHTTP, policy != "no-referrer", policy != "same-origin" || sameOrigin,
           !downgrade || ["unsafe-url", "origin", "origin-when-cross-origin"].contains(policy) {
            request.setValue(referrer?.string, forHTTPHeaderField: "Referer")
        }
        let scopedCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = url.host?.lowercased() ?? ""
            let domainMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let sourceHost = source.host?.lowercased() ?? ""
            let belongsToPublisher = sourceHost == domain || (cookie.domain.hasPrefix(".") && sourceHost.hasSuffix("." + domain))
            // Cookie Path matching uses the request URI's path, without
            // percent-decoding. Decoding here can both withhold a valid cookie
            // and forward a differently scoped cookie to an escaped path.
            let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
            let path = encodedPath.isEmpty ? "/" : encodedPath
            let prefixMatches = path.hasPrefix(cookie.path) && (path == cookie.path || cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))
            // A native request must not forward unrelated third-party login
            // cookies that WebKit's storage-access policy may have withheld.
            return domainMatches && belongsToPublisher && prefixMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: scopedCookies) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            completionHandler(nil); return
        }
        var redirected = Self.request(url: url, source: entry.sourceURL, cookies: cookies, referrerPolicy: entry.referrerPolicy)
        redirected.setValue(entry.cookieContext.userAgent, forHTTPHeaderField: "User-Agent")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            || entry.allowsCookies && challenge.protectionSpace.host.lowercased() == entry.sourceURL.host?.lowercased() {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { responseFailure = URLError(.badServerResponse); completionHandler(.cancel); return }
        guard (200..<300).contains(http.statusCode) else { responseFailure = ReaderAssetRequestFailure.httpStatus(http.statusCode); completionHandler(.cancel); return }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            responseFailure = URLError(.dataLengthExceedsMaximum); completionHandler(.cancel); return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        let accepted: Bool
        switch entry.resource {
        case .image: accepted = ["image/jpeg", "image/jpg", "image/pjpeg", "image/png", "image/x-png", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif", "image/svg+xml", "image/bmp", "image/tiff", "image/x-icon", "image/vnd.microsoft.icon"].contains(mime)
        case .caption: accepted = ["text/vtt", "text/plain", "application/octet-stream"].contains(mime)
        case .svgSymbol: accepted = ["image/svg+xml", "application/xml", "text/xml"].contains(mime)
        default: accepted = false
        }
        guard accepted else { responseFailure = URLError(.cannotDecodeContentData); completionHandler(.cancel); return }
        mimeType = mime
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count <= maximumBytes - chunk.count else { responseFailure = URLError(.dataLengthExceedsMaximum); dataTask.cancel(); return }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil; self.session = nil
        let cancelled = self.cancelled
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        if cancelled { continuation?.resume(throwing: CancellationError()); return }
        if let responseFailure { continuation?.resume(throwing: responseFailure); return }
        if let error { continuation?.resume(throwing: error); return }
        do {
            switch entry.resource {
            case .caption:
                let header = String(decoding: data.prefix(32), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                guard header == "WEBVTT" || header.hasPrefix("WEBVTT\n") || header.hasPrefix("WEBVTT\r") || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else { throw URLError(.cannotDecodeContentData) }
                continuation?.resume(returning: .init(data: data, mimeType: "text/vtt"))
            case .svgSymbol:
                let sanitized = try sanitizedReaderSVG(data, symbol: entry.resource.remoteURL?.fragment)
                continuation?.resume(returning: .init(data: sanitized, mimeType: "image/svg+xml"))
            case .image where mimeType == "image/svg+xml":
                continuation?.resume(returning: .init(data: try sanitizedReaderSVG(data, symbol: nil), mimeType: mimeType))
            default: continuation?.resume(returning: .init(data: data, mimeType: mimeType))
            }
        } catch { continuation?.resume(throwing: error) }
    }
}

func sanitizedReaderSVG(_ data: Data, symbol: String?) throws -> Data {
    guard data.count <= 2 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
    let doc = try SwiftSoup.parse(text, "", .xmlParser())
    try doc.select("script, foreignObject, style, link, iframe, object, embed, animate, animateTransform, animateMotion, set, mpath").remove()
    for element in try doc.getAllElements() {
        try preserveReaderGraphicPresentation(in: element)
        for attribute in element.getAttributes()?.asList() ?? [] {
            let key = attribute.getKey().lowercased()
            let value = attribute.getValue().trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("on") || key == "style" || key == "xml:base"
                || (["href", "xlink:href"].contains(key) && !value.hasPrefix("#")) {
                try element.removeAttr(attribute.getKey())
            }
        }
    }
    // Keep the complete sanitized symbol/defs set. References remain scoped
    // inside an isolated SVG image document; publisher IDs never enter Reader.
    if let symbol, !symbol.isEmpty {
        guard let target = try doc.getElementById(symbol.removingPercentEncoding ?? symbol),
              let root = try doc.select("svg").first() else { throw URLError(.resourceUnavailable) }
        if target === root { return Data(try doc.outerHtml().utf8) }
        let viewBox = try target.attr("viewBox")
        if !viewBox.isEmpty { try root.attr("viewBox", viewBox) }
        // An external <use> paints only the referenced subtree. Keep the other
        // nodes available for local references without painting the entire
        // source sprite sheet behind the selected symbol or group.
        let definitions = try doc.createElement("defs")
        for child in root.getChildNodes() { try definitions.appendChild(child) }
        try root.appendChild(definitions)
        let use = try doc.createElement("use")
        try use.attr("href", "#" + (try target.id()))
        try root.appendChild(use)
    }
    return Data(try doc.outerHtml().utf8)
}
