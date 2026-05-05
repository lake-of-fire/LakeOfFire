import Foundation

public struct EbookReaderProtocol: ReaderProtocol {
    public static let urlScheme = "ebook"
    
    public static func providesNativeReaderView(forURL url: URL) -> Bool {
        return false
    }
}
