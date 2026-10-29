import Foundation
import LakeOfFireCore
import WebKit

/// Ephemeral capabilities, never serialized back into a content record. The
/// original URL and MIME information remain in the canonical article markup.
enum ReaderDocumentResource: Sendable {
    case image(URL)
    case caption(URL)
    case remoteMedia(URL)
    case svgSymbol(URL)
    case remoteHTML(URL, permissions: String, sandbox: String?, referrerPolicy: String?)
    case inlineHTML(String)
    case mediaFile(URL, mimeType: String)

    var remoteURL: URL? {
        switch self {
        case .image(let url), .caption(let url), .remoteMedia(let url), .svgSymbol(let url), .remoteHTML(let url, _, _, _): return url
        case .inlineHTML, .mediaFile: return nil
        }
    }
}

/// The wrapper must not disclose its capability path to a provider. Preserve
/// stricter publisher restrictions while capping permissive policies at origin.
func readerEmbedReferrerPolicy(_ author: String?) -> String {
    switch normalizedReaderReferrerPolicy(author) {
    case "no-referrer": return "no-referrer"
    case "same-origin": return "same-origin"
    case "strict-origin": return "strict-origin"
    default: return "strict-origin-when-cross-origin"
    }
}

func readerRemoteEmbedConfiguration(
    registration: String, provider: URL, permissions: String,
    sandbox: String?, referrerPolicy: String?
) throws -> String {
    let configuration: [String: Any] = ["registration": registration, "provider": provider.absoluteString,
        "permissions": permissions, "sandbox": sandbox as Any? ?? NSNull(),
        "referrerPolicy": readerEmbedReferrerPolicy(referrerPolicy)]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
        .replacingOccurrences(of: "<", with: "\\u003c")
    // Match the bundled wrapper's bound before registering an unusable frame.
    guard json.utf8.count <= 16_384 else { throw URLError(.dataLengthExceedsMaximum) }
    return json
}

/// One owner per prepared document; releasing it revokes all resource URLs and
/// cancels outstanding work. Separate windows never revoke each other's media.
final class ReaderDocumentPresentation: @unchecked Sendable {
    let generation: UUID
    let sourceURL: URL
    let cookieContext = ReaderResourceCookieContext()
    private let lock = NSLock()
    private var registrations: [String] = []
    private var inlineContentBytes = 0
    private var documentURL: URL?
    private var released = false

    init(sourceURL: URL, generation: UUID) {
        self.sourceURL = sourceURL
        self.generation = generation
    }

    func register(_ resource: ReaderDocumentResource, referrerPolicy: String? = nil, allowsCookies: Bool = true) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !released, registrations.count < 2_048 else { throw URLError(.dataLengthExceedsMaximum) }
        if case .inlineHTML(let html) = resource {
            let bytes = html.utf8.count
            guard bytes <= 2 * 1_024 * 1_024 - inlineContentBytes else { throw URLError(.dataLengthExceedsMaximum) }
            inlineContentBytes += bytes
        }
        let id = UUID().uuidString.lowercased()
        if case .remoteHTML(let provider, let permissions, let sandbox, let policy) = resource {
            _ = try readerRemoteEmbedConfiguration(registration: id, provider: provider,
                permissions: permissions, sandbox: sandbox, referrerPolicy: policy)
        }
        ReaderDocumentResourceRegistry.shared.insert(id: id, resource: resource, owner: self, referrerPolicy: referrerPolicy, allowsCookies: allowsCookies)
        registrations.append(id)
        ReaderLoadTrace.$operationID.withValue(generation) {
            ReaderLoadTrace.event("reader.resourceRegistered", "component=\(ReaderDocumentResourceRegistry.shared.entry(for: id)?.diagnosticID.uuidString ?? "none") count=\(registrations.count)")
        }
        return id
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let ids = registrations
        let documentURL = self.documentURL
        self.documentURL = nil
        registrations.removeAll()
        lock.unlock()
        ReaderDocumentResourceRegistry.shared.remove(ids: ids)
        if let documentURL { ReaderDocumentResourceRegistry.shared.removeDocument(at: documentURL, generation: generation) }
    }

    func installDocument(_ data: Data, at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !released, data.count <= 64 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        if let previous = documentURL, previous.removingFragmentIfNeeded() != url.removingFragmentIfNeeded() {
            ReaderDocumentResourceRegistry.shared.removeDocument(at: previous, generation: generation)
        }
        documentURL = url
        ReaderDocumentResourceRegistry.shared.installDocument(data, at: url, generation: generation, cookies: cookieContext)
    }

    deinit { release() }
}

final class ReaderDocumentResourceRegistry: @unchecked Sendable {
    static let shared = ReaderDocumentResourceRegistry()
    struct Entry: Sendable {
        let diagnosticID = UUID()
        let resource: ReaderDocumentResource
        let sourceURL: URL
        let generation: UUID
        let referrerPolicy: String?
        let allowsCookies: Bool
        let cookieContext: ReaderResourceCookieContext
    }
    private struct Registration {
        let entry: Entry
        var cancellations: [UUID: @Sendable () -> Void] = [:]
    }
    private let lock = NSLock()
    private var entries: [String: Registration] = [:]
    struct Document {
        let generation: UUID
        let data: Data
        let cookieContext: ReaderResourceCookieContext
    }
    private var documents: [URL: Document] = [:]

    fileprivate func installDocument(_ data: Data, at url: URL, generation: UUID, cookies: ReaderResourceCookieContext) {
        lock.lock(); defer { lock.unlock() }
        documents[url.removingFragmentIfNeeded()] = Document(generation: generation, data: data, cookieContext: cookies)
    }

    func document(at url: URL) -> Document? {
        lock.lock(); defer { lock.unlock() }
        return documents[url.removingFragmentIfNeeded()]
    }

    /// Prepared HTML belongs to one navigation. A later raw WebKit reload or
    /// history request must enter normal reconstruction with fresh resources.
    func takeDocument(at url: URL) -> Document? {
        lock.lock(); defer { lock.unlock() }
        return documents.removeValue(forKey: url.removingFragmentIfNeeded())
    }

    fileprivate func removeDocument(at url: URL, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        let key = url.removingFragmentIfNeeded()
        if documents[key]?.generation == generation { documents.removeValue(forKey: key) }
    }

    fileprivate func insert(id: String, resource: ReaderDocumentResource, owner: ReaderDocumentPresentation, referrerPolicy: String?, allowsCookies: Bool) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = Registration(entry: Entry(resource: resource, sourceURL: owner.sourceURL, generation: owner.generation, referrerPolicy: referrerPolicy, allowsCookies: allowsCookies, cookieContext: owner.cookieContext))
    }

    func entry(for id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.entry
    }

    /// Attaching after revocation immediately cancels the work instead of
    /// allowing a late request to outlive its presentation.
    func attach(id: String, request: UUID, cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        guard entries[id] != nil else { lock.unlock(); cancellation(); return }
        entries[id]?.cancellations[request] = cancellation
        lock.unlock()
    }

    func finish(id: String, request: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[id]?.cancellations.removeValue(forKey: request)
    }

    fileprivate func remove(ids: [String]) {
        lock.lock()
        let removed = ids.compactMap { entries.removeValue(forKey: $0) }
        lock.unlock()
        for registration in removed {
            for cancel in registration.cancellations.values { cancel() }
        }
    }
}

/// Shares the owning WebKit cookie store with native static dependencies,
/// including those rendered inside a sanitized local srcdoc. Provider frames
/// retain WebKit's ordinary cookie policy on their real network origins.
final class ReaderResourceCookieContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var store: WKHTTPCookieStore?
    private var persistent = false
    private var boundUserAgent: String?
    private let transientAuthenticatedCache = URLCache(memoryCapacity: 8 * 1_024 * 1_024, diskCapacity: 0, diskPath: nil)
    private let transientAnonymousCache = URLCache(memoryCapacity: 8 * 1_024 * 1_024, diskCapacity: 0, diskPath: nil)
    private static let anonymousCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 64 * 1_024 * 1_024, diskPath: "manabi-reader-anonymous-assets")
    func bind(_ dataStore: WKWebsiteDataStore, userAgent: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        store = dataStore.httpCookieStore
        persistent = dataStore.isPersistent
        if let userAgent { boundUserAgent = userAgent }
    }
    var userAgent: String? { lock.lock(); defer { lock.unlock() }; return boundUserAgent }
    var permitsSharedCredentials: Bool { lock.lock(); defer { lock.unlock() }; return persistent }
    func cache(allowsCookies: Bool) -> URLCache {
        lock.lock(); defer { lock.unlock() }
        if persistent { return allowsCookies ? .shared : Self.anonymousCache }
        return allowsCookies ? transientAuthenticatedCache : transientAnonymousCache
    }
    private func currentStore() -> WKHTTPCookieStore? { lock.lock(); defer { lock.unlock() }; return store }

    @MainActor
    func cookies() async -> [HTTPCookie] {
        guard !Task.isCancelled, let store = currentStore() else { return [] }
        let receipt = ReaderCookieReceipt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                receipt.attach(continuation)
                guard !Task.isCancelled else { receipt.finish([]); return }
                let deadline = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    receipt.finish([])
                }
                store.getAllCookies { cookies in receipt.finish(cookies); deadline.cancel() }
            }
        } onCancel: { receipt.finish([]) }
    }
}

private final class ReaderCookieReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var continuation: CheckedContinuation<[HTTPCookie], Never>?
    func attach(_ continuation: CheckedContinuation<[HTTPCookie], Never>) {
        lock.lock()
        if settled { lock.unlock(); continuation.resume(returning: []); return }
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ cookies: [HTTPCookie]) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: cookies)
    }
}

func readerPresentationDocumentURL(baseURL: URL) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    // A presentation capability, distinct from the diagnostic generation.
    // Multiple windows can show one source without sharing mutable HTML.
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "reader-document" }
    items.append(URLQueryItem(name: "reader-document", value: UUID().uuidString.lowercased()))
    components.queryItems = items
    return components.url!
}

func readerRegisteredResourceURL(_ id: String, resolveEmbed: Bool = false) -> URL {
    // Only locally generated UUIDs reach this builder. No arbitrary fetch URL
    // or filesystem path is accepted by either transport.
    URL(string: "internal://local/\(resolveEmbed ? "reader-embed" : "reader-asset")/\(id)")!
}

func readerRegistrationID(in url: URL, prefix: String, allowsFragment: Bool = false) -> String? {
    let components = url.path.split(separator: "/")
    guard components.count == 2, components[0] == prefix,
          UUID(uuidString: String(components[1])) != nil,
          url.query == nil, (allowsFragment || url.fragment == nil) else { return nil }
    return String(components[1])
}
