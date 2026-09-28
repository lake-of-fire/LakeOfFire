import Foundation

public struct Publication: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var author: String?
    public var publicationDate: Date?
    public var coverURL: URL?
    public var downloadURL: URL?
    public var summary: String?
    public var hasContentAudio = false
}
