import Foundation

/// Metadata-only eligibility, not a snapshot or a lease against provider
/// eviction. Does not read file payloads, coordinate a read, or request downloads.
/// The caller still has to capture/validate an owned package before enrollment.
enum ReaderEBookLocalAvailability {
    /// Comes from ReaderFileManager's validated app-owned storage root, not an
    /// inferred pathname or a default for missing resource metadata.
    enum StorageLocation { case local, iCloud }

    static func allowsReading(location: StorageLocation, isUbiquitous: Bool?,
                              downloadingStatus: URLUbiquitousItemDownloadingStatus?,
                              isDownloading: Bool?) -> Bool {
        // Foundation can omit iCloud-only properties on ordinary local files.
        // Only a validated local root permits that absence. For an iCloud root,
        // even an absent/false membership flag must not waive download checks.
        let needsCloudState = location == .iCloud || isUbiquitous == true
        return !needsCloudState || (downloadingStatus == .current && isDownloading == false)
    }

    static func isAlreadyReadable(at root: URL, location: StorageLocation, maximumEntries: Int = 65_534) throws -> Bool {
        guard root.isFileURL, root.baseURL == nil, maximumEntries >= 0 else {
            throw ReaderEBookPackageSnapshotError.invalidSource
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        func inspect(_ url: URL) throws -> (readable: Bool, directory: Bool) {
            try Task.checkCancellation()
            // Unlike the old metadata hint, failed property reads do not
            // acquire constructor/default 'current' status.
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw ReaderEBookPackageSnapshotError.unsupportedSource
            }
            let readable = allowsReading(location: location,
                isUbiquitous: values.isUbiquitousItem,
                downloadingStatus: values.ubiquitousItemDownloadingStatus,
                isDownloading: values.ubiquitousItemIsDownloading)
            return (readable, values.isDirectory == true)
        }
        let top = try inspect(root)
        guard top.readable else { return false }
        guard top.directory else { return true }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ReaderEBookPackageSnapshotError.unavailable
        }
        var count = 0
        for case let url as URL in enumerator {
            guard count < maximumEntries else { throw ReaderEBookPackageSnapshotError.limitExceeded }
            count += 1
            guard try inspect(url).readable else { return false }
        }
        if let enumerationError { throw enumerationError }
        try Task.checkCancellation()
        return true
    }
}
