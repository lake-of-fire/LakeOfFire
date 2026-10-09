import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Select a declared rendition from the owned bytes before fingerprinting. The
/// selected literal path is also sent to Foliate; it must not independently
/// choose another OPF from the same archive after reading state is resolved.
enum ReaderEBookRenditionSelection {
    static func path(in snapshot: ReaderEBookPackageSnapshot, preferred: String?,
                     limits: ReaderEBookFingerprintLimits) throws -> String {
        try snapshot.validateObservation(snapshot.observationToken)
        _ = try ReaderEBookZIPDirectory.validate(snapshot.packageURL, maximumEntryCount: limits.maxEntryCount)
        let archive = try Archive(url: snapshot.packageURL, accessMode: .read)
        guard let entry = archive["META-INF/container.xml"], entry.type == .file else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        let limit = UInt64(min(1_048_576, limits.maxEntryBytes, limits.maxAggregateUncompressedBytes))
        guard entry.uncompressedSize <= limit else { throw ReaderEBookFingerprintError.limitExceeded }
        var data = Data()
        let checksum = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard UInt64(chunk.count) <= entry.uncompressedSize - UInt64(data.count),
                  UInt64(chunk.count) <= limit - UInt64(data.count) else {
                throw ReaderEBookFingerprintError.sizeChanged(entry.path)
            }
            data.append(chunk)
        }
        guard UInt64(data.count) == entry.uncompressedSize, checksum == entry.checksum else {
            throw ReaderEBookFingerprintError.checksumMismatch(entry.path)
        }
        try snapshot.validateObservation(snapshot.observationToken)
        let paths = try packageDocuments(in: data)
        if let preferred {
            guard paths.contains(where: { $0.utf8.elementsEqual(preferred.utf8) }) else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            return preferred
        }
        return paths[0]
    }

    static func packageDocuments(in data: Data) throws -> [String] {
        guard data.count <= 1_048_576 else { throw ReaderEBookFingerprintError.limitExceeded }
        final class Delegate: NSObject, XMLParserDelegate {
            let namespace = "urn:oasis:names:tc:opendocument:xmlns:container"
            var stack: [(String, String?)] = []
            var paths = [String]()
            var rejected = false
            func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                stack.append((name, namespaceURI))
                if stack.count == 1 {
                    if name != "container" || namespaceURI != namespace { reject(parser) }
                    return
                }
                guard name == "rootfile", namespaceURI == namespace,
                      attributes["media-type"] == "application/oebps-package+xml" else { return }
                guard stack.count == 3, stack[1].0 == "rootfiles", stack[1].1 == namespace,
                      paths.count < 256, let path = attributes["full-path"],
                      (try? ReaderEBookPackageFingerprint.validatePath(path)) != nil else {
                    reject(parser); return
                }
                paths.append(path)
            }
            func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
                if !stack.isEmpty { stack.removeLast() }
            }
            func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { reject(parser) }
            func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { reject(parser) }
            func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? {
                reject(parser); return nil
            }
        }
        try Task.checkCancellation()
        let delegate = Delegate(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, !delegate.rejected, !delegate.paths.isEmpty else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        try Task.checkCancellation()
        return delegate.paths
    }
}
