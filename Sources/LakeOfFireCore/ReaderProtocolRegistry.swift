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

public class ReaderProtocolRegistry {
    public static let shared = ReaderProtocolRegistry(readerProtocols: [
        EbookReaderProtocol.self,
        InternalReaderProtocol.self,
    ])
    
    public init(readerProtocols: [ReaderProtocol.Type]) {
        for readerProtocol in readerProtocols {
            register(readerProtocol)
        }
    }
    
    var readerProtocols: [ReaderProtocol.Type] = []
    
    public func register(_ readerProtocol: ReaderProtocol.Type) {
        readerProtocols.append(readerProtocol)
    }
    
    public func get(forURL url: URL) -> ReaderProtocol.Type? {
        guard let scheme = url.scheme else { return nil }
        return readerProtocols.first { $0.urlScheme == scheme }
    }
}
