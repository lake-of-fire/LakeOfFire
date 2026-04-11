import Foundation

public extension URL {
    @MainActor
    var isNativeReaderView: Bool {
        if absoluteString == "about:blank" {
            return true
        }
        return ReaderProtocolRegistry.shared.get(forURL: self)?.providesNativeReaderView(forURL: self) ?? false
    }
}
