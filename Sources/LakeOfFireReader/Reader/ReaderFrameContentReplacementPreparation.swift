import Foundation

/// One in-place render owns one DOM token. It grants no native reading
/// authority; the prepared commit retains the original native owner.
@MainActor
public struct ReaderFrameContentReplacementPreparation {
    public let token: String
    private let commitReplacement: @MainActor () -> Bool
    private let discardPreparation: @MainActor () async -> Void

    public init(token: String, commit: @escaping @MainActor () -> Bool,
        discard: @escaping @MainActor () async -> Void = {}) {
        self.token = token
        self.commitReplacement = commit
        self.discardPreparation = discard
    }

    public func commit() -> Bool {
        commitReplacement()
    }

    public func discard() async {
        await discardPreparation()
    }

    public static let documentGuardScript: String? = {
        guard let url = Bundle.module.url(forResource: "reader-frame-replacement-guard",
            withExtension: "js", subdirectory: "Resources/Resources") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// This check and the DOM effects execute in the same page-world call.
    /// A same-frame navigation cannot receive a predecessor's replacement.
    public func guardedScript(_ replacementScript: String) -> String? {
        guard let guardScript = Self.documentGuardScript else { return nil }
        return """
        const readerFrameReplacementGuard = \(guardScript);
        if (!readerFrameReplacementGuard.consume(readerFrameReplacementToken)) return false;
        \(replacementScript)
        return true;
        """
    }
}
