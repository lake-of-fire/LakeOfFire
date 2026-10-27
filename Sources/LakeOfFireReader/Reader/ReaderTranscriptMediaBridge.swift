import Foundation

/// An immutable selection from one physical page document. Native callers must
/// also retain their WebViewScriptCaller binding and selection ownership.
public struct ReaderTranscriptMediaSnapshot: Decodable, Sendable {
    public let documentURL: URL
    public let documentID: String
    public let title: String
    public let mediaURL: URL?
    public let mediaIdentity: String
    public let stableProviderIdentity: String?
    public let duration: TimeInterval?
    public let languageCode: String?
    public let webVTT: String?
    public let captionURL: URL?
    /// Opaque selection token, scoped to this document, including track URL and language.
    public let captionSelectionIdentity: String?
    public let mimeType: String

    public init(documentURL: URL, documentID: String, title: String,
                mediaURL: URL?, mediaIdentity: String, stableProviderIdentity: String? = nil,
                duration: TimeInterval? = nil,
                languageCode: String? = nil, webVTT: String? = nil,
                captionURL: URL? = nil, captionSelectionIdentity: String? = nil, mimeType: String = "") {
        self.documentURL = documentURL
        self.documentID = documentID
        self.title = title
        self.mediaURL = mediaURL
        self.mediaIdentity = mediaIdentity
        self.stableProviderIdentity = stableProviderIdentity
        self.duration = duration
        self.languageCode = languageCode
        self.webVTT = webVTT
        self.captionURL = captionURL
        self.captionSelectionIdentity = captionSelectionIdentity
        self.mimeType = mimeType
    }
}

public enum ReaderTranscriptMediaBridge {
    public static func decode(_ json: String) throws -> ReaderTranscriptMediaSnapshot {
        try JSONDecoder().decode(ReaderTranscriptMediaSnapshot.self, from: Data(json.utf8))
    }

    /// No network work occurs here, so saved transcripts can be reused first.
    public static let snapshotJavaScript = loadScript("reader-transcript-snapshot")

    /// Evaluate only after saved reuse fails. Browser fetch owns cookie scoping;
    /// neither native media requests nor another origin receive exported cookies.
    public static let captionsJavaScript = loadScript("reader-transcript-captions")

    private static func loadScript(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js",
            subdirectory: "Resources/Transcript"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing transcript JavaScript resource: \(name)")
        }
        return source
    }
}
