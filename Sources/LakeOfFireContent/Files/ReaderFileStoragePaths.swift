import Foundation

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
        let name = fileURL.lastPathComponent
        if name.hasSuffix(".sha1verified.json") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        for index in parts.indices where index > 0 && index + 1 < parts.count {
            let marker = parts[index]
            guard marker == "downloading" || marker == "decompressing" else { continue }
            let identifier = String(parts[index + 1])
            guard identifier.count == 36, let uuid = UUID(uuidString: identifier),
                  uuid.uuidString.lowercased() == identifier.lowercased() else { continue }
            let suffixCount = parts.count - index - 2
            // Downloadable writes base.downloading.UUID[.extension][.br],
            // or destination.decompressing.UUID. Do not hide similarly named
            // ordinary files without an exact operation UUID and suffix shape.
            if marker == "downloading",
               suffixCount <= 1 || (suffixCount == 2 && parts.last == "br") { return true }
            if marker == "decompressing", suffixCount == 0 { return true }
        }
        return false
    }
}
