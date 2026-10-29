import Foundation
import Network
import LakeOfFireCore

/// A capability server for Reader's bundled HTML wrappers and registered
/// resources. This is deliberately not a URL proxy or filesystem server.
final class ReaderLoopbackServer: @unchecked Sendable {
    static let shared = ReaderLoopbackServer()
    private let queue = DispatchQueue(label: "io.manabi.reader.loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [UUID: ReaderLoopbackPortReceipt] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var connectionCleanup: [UUID: @Sendable () -> Void] = [:]

    func url(for id: String) async throws -> URL {
        guard let entry = ReaderDocumentResourceRegistry.shared.entry(for: id) else { throw URLError(.cancelled) }
        let route: String
        switch entry.resource {
        case .remoteHTML: route = "embed"
        case .inlineHTML: route = "inline"
        case .mediaFile: route = "media"
        case .remoteMedia: throw URLError(.unsupportedURL)
        default: route = "asset"
        }
        let port = try await readyPort()
        try Task.checkCancellation()
        guard ReaderDocumentResourceRegistry.shared.entry(for: id) != nil else { throw URLError(.cancelled) }
        return URL(string: "http://127.0.0.1:\(port)/\(route)/\(id)")!
    }

    private func readyPort() async throws -> UInt16 {
        let id = UUID()
        let receipt = ReaderLoopbackPortReceipt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receipt.attach(continuation)
                queue.async {
                    guard !receipt.isSettled else { return }
                    if let port = self.port { receipt.finish(.success(port)); return }
                    guard self.waiters.count < 128 else { receipt.finish(.failure(URLError(.resourceUnavailable))); return }
                    self.waiters[id] = receipt
                    self.startIfNeeded()
                    self.queue.asyncAfter(deadline: .now() + 4) {
                        self.waiters.removeValue(forKey: id)?.finish(.failure(URLError(.timedOut)))
                    }
                }
            }
        } onCancel: {
            receipt.finish(.failure(CancellationError()))
            self.queue.async { self.waiters.removeValue(forKey: id) }
        }
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        let span = ReaderLoadTrace.begin("reader.embedServerStartup")
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = false
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, self.listener === listener, self.connections.count < 32 else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue else { return }
                    self.port = port
                    let waiting = self.waiters.values; self.waiters.removeAll()
                    for waiter in waiting { waiter.finish(.success(port)) }
                    span?.end("status=ready")
                case .failed:
                    self.stopOnQueue()
                    span?.end("status=failed")
                default: break
                }
            }
            listener.start(queue: queue)
        } catch {
            stopOnQueue()
            span?.end("status=failed")
        }
    }

    /// Registrations survive a transport restart; callers resolve a fresh port
    /// through their stable internal capability URL on an embed-only retry.
    func restart() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        listener?.cancel(); listener = nil; port = nil
        for connection in connections.values { connection.cancel() }
        let cleanup = connectionCleanup.values
        connectionCleanup.removeAll()
        for finish in cleanup { finish() }
        connections.removeAll()
        let waiting = waiters.values; waiters.removeAll()
        for waiter in waiting { waiter.finish(.failure(URLError(.cannotConnectToHost))) }
        ReaderLoadTrace.event("reader.embedServerStopped")
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: id)
                self?.connectionCleanup.removeValue(forKey: id)?()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak connection] in
            guard self?.connections[id] != nil else { return }
            connection?.cancel()
        }
        receive(connection, id: id, data: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192 - data.count) { [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] === connection else { return }
            var buffer = data
            if let chunk { buffer.append(chunk) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == buffer.count,
                      let port = self.port,
                      let request = ReaderLoopbackRequest.parse(buffer, port: port) else {
                    self.send(.error(400), to: connection); return
                }
                self.serve(request, connection: connection, connectionID: id)
            } else if buffer.count >= 8_192 || complete || error != nil {
                self.send(.error(400), to: connection)
            } else {
                self.receive(connection, id: id, data: buffer)
            }
        }
    }

    private func serve(_ request: ReaderLoopbackRequest, connection: NWConnection, connectionID: UUID) {
        if request.path == "/reader-embed.js" || request.path == "/reader-components.js" {
            let name = request.path == "/reader-embed.js" ? "reader-embed" : "reader-components"
            guard let data = readerBundledComponent(name, extension: "js") else { send(.error(500), to: connection); return }
            send(.init(status: 200, mime: "text/javascript", body: .data(data)), to: connection, head: request.method == "HEAD")
            return
        }
        guard let url = URL(string: "http://127.0.0.1" + request.path),
              let route = url.path.split(separator: "/").first,
              let id = readerRegistrationID(in: url, prefix: String(route)),
              let entry = ReaderDocumentResourceRegistry.shared.entry(for: id) else { send(.error(404), to: connection); return }
        let requestID = UUID()
        let work = Task {
            let response: ReaderLoopbackResponse
            do {
                switch (String(route), entry.resource) {
                case ("resolve", .remoteHTML), ("resolve", .inlineHTML), ("resolve", .mediaFile):
                    let url = try await self.url(for: id)
                    response = .init(status: 200, mime: "application/json", body: .data(try JSONSerialization.data(withJSONObject: ["url": url.absoluteString])))
                case ("embed", .remoteHTML(let provider, let permissions, let sandbox, let referrerPolicy)):
                    response = try Self.wrapper(id: id, provider: provider, permissions: permissions, sandbox: sandbox, referrerPolicy: referrerPolicy)
                case ("inline", .inlineHTML(let html)):
                    response = .init(status: 200, mime: "text/html; charset=utf-8", body: .data(Data(html.utf8)), headers: [
                        "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; media-src 'self' https: http:; frame-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'"
                    ])
                case ("media", .mediaFile(let file, let mime)):
                    response = try ReaderLoopbackResponse.mediaFile(file, mime: mime, range: request.range)
                case ("asset", .image), ("asset", .caption), ("asset", .svgSymbol):
                    let cookies = entry.allowsCookies ? await entry.cookieContext.cookies() : []
                    let asset = try await ReaderAssetService.shared.load(entry: entry, cookies: cookies)
                    response = .init(status: 200, mime: asset.mimeType, body: .data(asset.data))
                default: response = .error(404)
                }
            } catch {
                response = .error(502)
            }
            self.queue.async {
                guard self.connections[connectionID] === connection,
                      ReaderDocumentResourceRegistry.shared.entry(for: id) != nil else { connection.cancel(); return }
                ReaderLoadTrace.$operationID.withValue(entry.generation) {
                    ReaderLoadTrace.event("reader.embedRequest", "component=\(entry.diagnosticID) status=\(response.status)")
                }
                self.send(response, to: connection, head: request.method == "HEAD")
            }
        }
        connectionCleanup[connectionID] = {
            work.cancel()
            ReaderDocumentResourceRegistry.shared.finish(id: id, request: requestID)
        }
        ReaderDocumentResourceRegistry.shared.attach(id: id, request: requestID) {
            work.cancel()
            connection.cancel()
        }
    }

    private static func wrapper(id: String, provider: URL, permissions: String, sandbox: String?, referrerPolicy: String?) throws -> ReaderLoopbackResponse {
        guard let template = readerBundledComponent("reader-embed", extension: "html"),
              let html = String(data: template, encoding: .utf8),
              let origin = URLComponents(url: provider, resolvingAgainstBaseURL: false).map({ components -> String in
                  var origin = components; origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
                  return origin.string ?? ""
              }), !origin.isEmpty else { throw URLError(.badURL) }
        let json = try readerRemoteEmbedConfiguration(registration: id, provider: provider,
            permissions: permissions, sandbox: sandbox, referrerPolicy: referrerPolicy)
        let data = Data(html.replacingOccurrences(of: "READER_COMPONENT_CONFIGURATION", with: json).utf8)
        return .init(status: 200, mime: "text/html; charset=utf-8", body: .data(data), headers: [
            "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; frame-src \(origin); connect-src 'none'; base-uri 'none'; form-action 'none'"
        ])
    }

    private func send(_ response: ReaderLoopbackResponse, to connection: NWConnection, head: Bool = false) {
        var headers = response.headers
        headers["Content-Type"] = response.mime
        headers["Content-Length"] = String(response.body.length)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        headers["X-Content-Type-Options"] = "nosniff"
        let header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Reader response")\r\n"
            + headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, !head else { connection.cancel(); return }
            switch response.body {
            case .data(let data): connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
            case .file(let url, let range):
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    try file.seek(toOffset: range.lowerBound)
                    self?.sendFile(file, remaining: range.upperBound - range.lowerBound, to: connection)
                } catch { connection.cancel() }
            }
        })
    }

    private func sendFile(_ file: FileHandle, remaining: UInt64, to connection: NWConnection) {
        guard remaining > 0 else { try? file.close(); connection.cancel(); return }
        do {
            let data = try file.read(upToCount: Int(min(remaining, 256 * 1_024))) ?? Data()
            guard !data.isEmpty else { try? file.close(); connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? file.close(); connection.cancel(); return }
                self.sendFile(file, remaining: remaining - UInt64(data.count), to: connection)
            })
        } catch { try? file.close(); connection.cancel() }
    }
}

struct ReaderLoopbackRequest {
    let method: String
    let path: String
    let range: String?

    static func parse(_ data: Data, port: UInt16) -> Self? {
        guard data.count <= 8_192, let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else { return nil }
        // CRLF is one Swift Character. Remove four bytes, not four grapheme
        // clusters, or a minimal request loses the end of its Host field.
        let lines = String(decoding: data.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])), first[1].hasPrefix("/"),
              !first[1].hasPrefix("//"), !first[1].contains("?"), !first[1].contains("#") else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil, !value.contains("\r"), !value.contains("\n") else { return nil }
            fields[key] = value
        }
        guard fields["host"] == "127.0.0.1:\(port)", fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else { return nil }
        return .init(method: String(first[0]), path: String(first[1]), range: fields["range"])
    }
}

struct ReaderLoopbackResponse: Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(URL, Range<UInt64>)
        var length: UInt64 { switch self { case .data(let data): return UInt64(data.count); case .file(_, let range): return range.upperBound - range.lowerBound } }
    }
    let status: Int
    let mime: String
    let body: Body
    var headers: [String: String] = [:]
    static func error(_ status: Int) -> Self { .init(status: status, mime: "text/plain", body: .data(Data("Reader component unavailable".utf8))) }

    static func mediaFile(_ url: URL, mime: String, range: String?) throws -> Self {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count >= 0 else { throw URLError(.fileDoesNotExist) }
        let length = UInt64(count)
        let full = UInt64(0)..<length
        guard let range else { return .init(status: 200, mime: mime, body: .file(url, full), headers: ["Accept-Ranges": "bytes"]) }
        guard let selected = ReaderMediaByteRange.resolve(range, length: length) else {
            return .init(status: 416, mime: mime, body: .data(Data()), headers: ["Content-Range": "bytes */\(length)", "Accept-Ranges": "bytes"])
        }
        return .init(status: 206, mime: mime, body: .file(url, selected), headers: [
            "Accept-Ranges": "bytes", "Content-Range": "bytes \(selected.lowerBound)-\(selected.upperBound - 1)/\(length)"
        ])
    }
}

/// Cancellation may arrive before the server queue has installed its waiter.
/// Settle independently of that queue and resume each continuation once.
private final class ReaderLoopbackPortReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UInt16, Error>?
    private var continuation: CheckedContinuation<UInt16, Error>?
    var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func attach(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum ReaderMediaByteRange {
    static func resolve(_ header: String, length: UInt64) -> Range<UInt64>? {
        guard length > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let values = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2 else { return nil }
        guard values.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        if values[0].isEmpty {
            guard let suffix = UInt64(values[1]), suffix > 0 else { return nil }
            return (length - min(length, suffix))..<length
        }
        guard let start = UInt64(values[0]), start < length else { return nil }
        if values[1].isEmpty { return start..<length }
        guard let end = UInt64(values[1]), end >= start else { return nil }
        return start..<(min(end, length - 1) + 1)
    }
}

func readerBundledComponent(_ name: String, extension ext: String) -> Data? {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/ReaderComponents") else { return nil }
    return try? Data(contentsOf: url)
}
