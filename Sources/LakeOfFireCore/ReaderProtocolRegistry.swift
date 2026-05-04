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
    private var readerProtocols: [ReaderProtocol.Type] = []

    public init(readerProtocols: [ReaderProtocol.Type]) {
        for readerProtocol in readerProtocols {
            register(readerProtocol)
        }
    }

    public func register(_ readerProtocol: ReaderProtocol.Type) {
        lock.withLock {
            readerProtocols.append(readerProtocol)
        }
    }

    public func get(forURL url: URL) -> ReaderProtocol.Type? {
        guard let scheme = url.scheme else { return nil }
        return lock.withLock {
            readerProtocols.first { $0.urlScheme == scheme }
        }
    }
}
