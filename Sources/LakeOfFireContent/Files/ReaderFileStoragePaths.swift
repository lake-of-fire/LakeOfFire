import Foundation
import SwiftUIDownloads

/// Storage names are not book identity. A remote locator owns its download slot;
/// content deduplication remains the responsibility of ReaderFileImportStorage.
enum ReaderFileStoragePaths {
    static let downloadsDirectory = "manabi-downloads-v1"

    static func downloadIdentity(for url: URL) -> String {
        // Fragments are not sent in a resource request. Keep the query and its
        // escaping byte-for-byte: they can select different books or signatures.
        let absolute = url.absoluteURL.absoluteString
        guard let fragment = absolute.firstIndex(of: "#") else { return absolute }
        return String(absolute[..<fragment])
    }

    static func downloadFilename(for url: URL) throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              name.utf8.count <= 255 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return name
    }

    static func isDownloadArtifact(_ fileURL: URL) -> Bool {
        DownloadStagingPaths.isDownloadArtifact(fileURL)
    }
}
