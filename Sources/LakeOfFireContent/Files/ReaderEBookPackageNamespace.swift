import Foundation

/// OCF names must be unique within their parent after canonical normalization
/// and full case folding. Check implicit directories too: `OPS/a` + `ops/b`
/// is ambiguous even though the complete paths do not collide. Original path
/// bytes remain untouched in the fingerprint; folding is only rejection logic.
enum ReaderEBookPackageNamespace {
    private struct Entry {
        let path: String
        let isDirectory: Bool
        let key: Data
    }

    /// Inputs have already passed the scanner's path/count/byte limits. Using
    /// component separators that sort before any name byte makes each parent
    /// and all its descendants contiguous. Adjacent entries then suffice; this
    /// avoids storing every ancestor of arbitrarily deep package paths.
    static func conflictingPath(in paths: [(path: String, isDirectory: Bool)]) throws -> String? {
        let locale = Locale(identifier: "en_US_POSIX")
        let entries = try paths.map { item -> Entry in
            try Task.checkCancellation()
            let folded = item.path.decomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: locale)
                .precomposedStringWithCanonicalMapping
            let key = Data(folded.utf8.map { $0 == 0x2f ? UInt8(0) : $0 })
            return Entry(path: item.path, isDirectory: item.isDirectory, key: key)
        }.sorted {
            if $0.key == $1.key { return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            return $0.key.lexicographicallyPrecedes($1.key)
        }
        guard entries.count > 1 else { return nil }
        for index in 1..<entries.count {
            try Task.checkCancellation()
            let previous = entries[index - 1], current = entries[index]
            let a = previous.key.split(separator: 0, omittingEmptySubsequences: false)
            let b = current.key.split(separator: 0, omittingEmptySubsequences: false)
            let originalA = previous.path.split(separator: "/", omittingEmptySubsequences: false)
            let originalB = current.path.split(separator: "/", omittingEmptySubsequences: false)
            var shared = 0
            while shared < min(a.count, b.count), a[shared] == b[shared] {
                // A different spelling of the same folded parent is unsafe,
                // even when the two leaf resource names are distinct.
                guard originalA[shared].utf8.elementsEqual(originalB[shared].utf8) else {
                    return current.path
                }
                shared += 1
            }
            if shared == a.count && (shared == b.count || !previous.isDirectory) {
                return previous.path
            }
        }
        return nil
    }
}
