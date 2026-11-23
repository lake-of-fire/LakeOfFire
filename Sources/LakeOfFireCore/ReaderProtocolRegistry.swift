import Foundation

public protocol ReaderProtocol {
    static var urlScheme: String { get }
    static func providesNativeReaderView(forURL url: URL) -> Bool
}

public extension ReaderProtocol {
    static func register(inReistry registry: ReaderProtocolRegistry = ReaderProtocolRegistry.shared) {
        registry.register(self)
    }
}

public final class ReaderProtocolRegistry: @unchecked Sendable {
    public static let shared = ReaderProtocolRegistry(readerProtocols: [
        EbookReaderProtocol.self,
        InternalReaderProtocol.self,
        TranscriptReaderProtocol.self,
    ])

    private let lock = NSLock()
    private var readerProtocols: [ReaderProtocol.Type]

    public init(readerProtocols: [ReaderProtocol.Type]) {
        self.readerProtocols = readerProtocols
    }

    public func register(_ readerProtocol: ReaderProtocol.Type) {
        lock.withLock {
            readerProtocols.append(readerProtocol)
        }
    }

    public func get(forURL url: URL) -> ReaderProtocol.Type? {
        guard let scheme = url.scheme else { return nil }
        // A conformer's scheme getter can call back into the registry.
        let registeredProtocols = lock.withLock { readerProtocols }
        return registeredProtocols.first { $0.urlScheme == scheme }
    }
}
