import Foundation

public struct TranscriptReaderProtocol: ReaderProtocol {
    public static let urlScheme = "transcript"

    public static func providesNativeReaderView(forURL url: URL) -> Bool {
        url.isTranscriptURL
    }
}
