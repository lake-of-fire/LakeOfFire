import Foundation
import LakeOfFire

public struct EbookReaderProtocol: ReaderProtocol {
    public static let urlScheme = "ebook"
    
    public static func providesNativeReaderView(forURL url: URL) -> Bool {
        return false
    }
}
