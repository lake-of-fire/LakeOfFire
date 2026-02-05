import SwiftUI

public protocol ReaderModeLoadHandling: AnyObject {
    func beginReaderModeLoad(for url: URL, suppressSpinner: Bool, reason: String?)
    func cancelReaderModeLoad(for url: URL?)
}

public struct ReaderModeLoadHandlerKey: EnvironmentKey {
    public static var defaultValue: (any ReaderModeLoadHandling)? = nil
}

public extension EnvironmentValues {
    var readerModeLoadHandler: (any ReaderModeLoadHandling)? {
        get { self[ReaderModeLoadHandlerKey.self] }
        set { self[ReaderModeLoadHandlerKey.self] = newValue }
    }
}
