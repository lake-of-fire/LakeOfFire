import Foundation

public struct InternalReaderProtocol: ReaderProtocol {
    public static let urlScheme = "internal"
    
    public static func providesNativeReaderView(forURL url: URL) -> Bool {
//        return host == "local" && path == "/snippet"
        return false
    }
}
