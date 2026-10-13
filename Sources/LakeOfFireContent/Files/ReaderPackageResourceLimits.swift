import Foundation

/// Bounds for package catalog inspection and individual resource reads.
/// Derived from v3-hotfix. A per-entry read limit does not reject unrelated
/// large media during metadata discovery; the catalog has a separate total.
public struct ReaderPackageResourceLimits: Sendable, Equatable {
    public let maxEntryCount: Int
    public let maxEntryBytes: Int64
    public let maxAggregateUncompressedBytes: Int64
    public let maxPathUTF8Bytes: Int
    public let maxAggregatePathUTF8Bytes: Int

    public init(
        maxEntryCount: Int = 100_000,
        maxEntryBytes: Int64 = 64 * 1024 * 1024,
        maxAggregateUncompressedBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maxPathUTF8Bytes: Int = 4096,
        maxAggregatePathUTF8Bytes: Int = 16 * 1024 * 1024
    ) {
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxEntryBytes = max(0, maxEntryBytes)
        self.maxAggregateUncompressedBytes = max(0, maxAggregateUncompressedBytes)
        self.maxPathUTF8Bytes = max(0, maxPathUTF8Bytes)
        self.maxAggregatePathUTF8Bytes = max(0, maxAggregatePathUTF8Bytes)
    }

    public static let `default` = Self()
    public static let metadata = Self(maxEntryCount: 25_000, maxEntryBytes: 8 * 1024 * 1024)
    public static let image = Self(maxEntryBytes: 128 * 1024 * 1024)

    func validateAdvertisedEntrySize(_ size: UInt64, path: String) throws {
        guard size <= UInt64(maxEntryBytes), size <= UInt64(Int.max) else {
            throw ReaderPackageEntrySourceError.entrySizeExceeded(
                path: path, size: Int64(clamping: size), limit: min(maxEntryBytes, Int64(Int.max))
            )
        }
    }
}

/// Account before storing another catalog entry. Count directories and links as
/// well as files so empty-directory or zero-byte archives cannot evade the bound.
/// Path bytes have their own cap: a small advertised payload can have huge names.
struct ReaderPackageCatalogBudget {
    let limits: ReaderPackageResourceLimits
    private(set) var entryCount = 0
    private(set) var uncompressedBytes: Int64 = 0
    private(set) var pathUTF8Bytes = 0

    mutating func include(path: String, uncompressedSize: UInt64) throws {
        guard entryCount < limits.maxEntryCount else {
            throw ReaderPackageEntrySourceError.entryCountExceeded(limit: limits.maxEntryCount)
        }
        let pathSize = path.utf8.count
        guard pathSize <= limits.maxPathUTF8Bytes else {
            throw ReaderPackageEntrySourceError.entryPathSizeExceeded(limit: limits.maxPathUTF8Bytes)
        }
        guard pathSize <= limits.maxAggregatePathUTF8Bytes - pathUTF8Bytes else {
            throw ReaderPackageEntrySourceError.aggregatePathSizeExceeded(limit: limits.maxAggregatePathUTF8Bytes)
        }
        guard uncompressedSize <= UInt64(limits.maxAggregateUncompressedBytes - uncompressedBytes) else {
            throw ReaderPackageEntrySourceError.aggregateSizeExceeded(limit: limits.maxAggregateUncompressedBytes)
        }
        // All additions are bounded by nonnegative representable maxima above.
        entryCount += 1
        pathUTF8Bytes += pathSize
        uncompressedBytes += Int64(uncompressedSize)
    }
}

/// The same actual-byte check protects ZIP extraction, filesystem reads, and
/// the legacy Archive.data convenience API. Never append an over-limit chunk.
struct ReaderPackageEntryAccumulator {
    let path: String
    let maximumBytes: Int64
    private(set) var data = Data()

    init(path: String, limits: ReaderPackageResourceLimits) {
        self.path = path
        self.maximumBytes = min(limits.maxEntryBytes, Int64(Int.max))
    }

    mutating func append(_ chunk: Data) throws {
        guard Int64(chunk.count) <= maximumBytes - Int64(data.count) else {
            throw ReaderPackageEntrySourceError.actualEntrySizeExceeded(path: path, limit: maximumBytes)
        }
        data.append(chunk)
    }
}
