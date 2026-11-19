import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Immutable decoding instructions owned by one package generation/rendition.
/// This never reads resources itself: the owner must authenticate raw bytes
/// before applying the transform, and keep query-backed JS reads untransformed.
struct ReaderEBookFontObfuscation: Sendable {
    private struct Decoder: Sendable {
        let key: [UInt8]
        let prefixLength: Int
    }
    private var decoders: [Data: Decoder] = [:]
    static let empty = Self()
    private static let metadataLimit = 1_048_576
    private static let opfNamespace = "http://www.idpf.org/2007/opf"
    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    private static let encryptionNamespace = "http://www.w3.org/2001/04/xmlenc#"

    static func prepare(entries: [ReaderPackageEntryMetadata], packageDocumentPath: String?,
                        readEntry: (String) throws -> Data) throws -> Self {
        let sizes = Dictionary(entries.map { (Data($0.path.utf8), $0.size) }, uniquingKeysWith: { first, _ in first })
        func metadata(_ path: String) throws -> Data? {
            try Task.checkCancellation()
            guard let size = sizes[Data(path.utf8)], size >= 0, size <= metadataLimit else { return nil }
            let data = try readEntry(path)
            guard data.count <= metadataLimit else { return nil }
            return data
        }
        guard let encryptionData = try metadata("META-INF/encryption.xml"),
              let encryption = try document(encryptionData),
              encryption.name == "encryption",
              encryption.namespace == "urn:oasis:names:tc:opendocument:xmlns:container" else { return .empty }
        let selectedPath: String
        if let packageDocumentPath { selectedPath = packageDocumentPath }
        else {
            // Legacy Foliate selects the first declared rendition. Do not guess
            // from arbitrary .opf filenames or use another generation's OPF.
            guard let container = try metadata("META-INF/container.xml"),
                  let paths = try? ReaderEBookRenditionSelection.packageDocuments(in: container),
                  let first = paths.first else {
                try Task.checkCancellation()
                return .empty
            }
            selectedPath = first
        }
        guard let opfData = try metadata(selectedPath), let opf = try document(opfData),
              opf.name == "package", opf.namespace == opfNamespace,
              let metadataNode = opf.children.first(where: { $0.isElement("metadata", opfNamespace) }) else { return .empty }
        let identifiers = metadataNode.children.filter { $0.isElement("identifier", dcNamespace) }
        let uniqueID = opf.attributes["unique-identifier"]
        let identifier = uniqueID.flatMap { id -> String? in
            let matches = identifiers.filter { $0.attributes["id"]?.utf8.elementsEqual(id.utf8) == true }
            return matches.count == 1 ? matches[0].textContent : nil
        }
        let stripped = identifier.map { value in
            String(String.UnicodeScalarView(value.unicodeScalars.filter {
                ![0x20, 0x09, 0x0d, 0x0a].contains($0.value)
            }))
        }
        let idpfKey = stripped.flatMap { $0.isEmpty ? nil : Array(Insecure.SHA1.hash(data: Data($0.utf8))) }
        // Adobe uses the UUID identifier, which need not be the OPF unique ID.
        let adobeKey = identifiers.compactMap { uuidKey($0.textContent) }.first
        var result = Self()
        var seen = Set<Data>()
        for encrypted in encryption.children where encrypted.isElement("EncryptedData", encryptionNamespace) {
            try Task.checkCancellation()
            let methods = encrypted.children.filter { $0.isElement("EncryptionMethod", encryptionNamespace) }
            let cipherData = encrypted.children.filter { $0.isElement("CipherData", encryptionNamespace) }
            guard cipherData.count == 1 else { continue }
            let references = cipherData[0].children.filter { $0.isElement("CipherReference", encryptionNamespace) }
            guard references.count == 1, let uri = references[0].attributes["URI"],
                  let path = resourcePath(uri), sizes[Data(path.utf8)] != nil else { continue }
            let pathKey = Data(path.utf8)
            // Conflicting/stacked declarations are not a supported XOR format.
            // Never choose a key based on declaration order.
            guard seen.insert(pathKey).inserted else { result.decoders.removeValue(forKey: pathKey); continue }
            guard methods.count == 1 else { continue }
            switch methods[0].attributes["Algorithm"] {
            case "http://www.idpf.org/2008/embedding":
                if let idpfKey { result.decoders[pathKey] = Decoder(key: idpfKey, prefixLength: 1040) }
            case "http://ns.adobe.com/pdf/enc#RC":
                if let adobeKey { result.decoders[pathKey] = Decoder(key: adobeKey, prefixLength: 1024) }
            default: break
            }
        }
        return result
    }

    func decode(_ rawBytes: Data, subpath: String) throws -> Data {
        try Task.checkCancellation()
        guard let decoder = decoders[Data(subpath.utf8)] else { return rawBytes }
        var bytes = rawBytes
        for offset in 0..<min(bytes.count, decoder.prefixLength) {
            bytes[bytes.startIndex + offset] ^= decoder.key[offset % decoder.key.count]
        }
        try Task.checkCancellation()
        return bytes
    }

    private static func uuidKey(_ value: String) -> [UInt8]? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        let uuid = trimmed.lowercased().hasPrefix("urn:uuid:") ? String(trimmed.dropFirst(9)) : trimmed
        guard uuid.utf8.count == 36, UUID(uuidString: uuid) != nil else { return nil }
        let hex = Array(uuid.replacingOccurrences(of: "-", with: "").utf8)
        guard hex.count == 32 else { return nil }
        let key = stride(from: 0, to: 32, by: 2).compactMap {
            UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)
        }
        return key.count == 16 ? key : nil
    }

    /// OCF CipherReference URIs are relative to the container root, not OPF or
    /// META-INF. Decode each component once; encoded separators never alias a
    /// different entry. A literal %2F filename must be referenced as %252F.
    private static func resourcePath(_ uri: String) -> String? {
        guard !uri.isEmpty, !uri.hasPrefix("//"), !uri.contains("?"), !uri.contains("#"),
              !uri.contains(":") else { return nil }
        let path = uri.hasPrefix("/") ? String(uri.dropFirst()) : uri
        var components: [String] = []
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false) {
            if encoded == "." { continue }
            if encoded == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
                continue
            }
            guard let component = String(encoded).removingPercentEncoding,
                  !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  !component.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
            components.append(component)
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private final class Node {
        let name: String
        let namespace: String?
        let attributes: [String: String]
        var children: [Node] = []
        enum Content { case text(String), element(Node) }
        var content: [Content] = []
        var textContent: String {
            content.map { item in
                switch item {
                case let .text(text): return text
                case let .element(node): return node.textContent
                }
            }.joined()
        }
        init(_ name: String, _ namespace: String?, _ attributes: [String: String]) {
            self.name = name; self.namespace = namespace; self.attributes = attributes
        }
        func isElement(_ name: String, _ namespace: String) -> Bool { self.name == name && self.namespace == namespace }
    }

    private final class DocumentParser: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        var rejected = false
        func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            count += 1
            guard !Task.isCancelled, stack.count < 64, count <= 25_000 else { reject(parser); return }
            let node = Node(name, namespaceURI, attributes)
            if let parent = stack.last { parent.children.append(node); parent.content.append(.element(node)) }
            else if root == nil { root = node }
            else { reject(parser); return }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            stack.last?.content.append(.text(String(decoding: data, as: UTF8.self)))
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? { reject(parser); return nil }
    }

    private static func document(_ data: Data) throws -> Node? {
        try Task.checkCancellation()
        let delegate = DocumentParser(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        return parsed && parser.parserError == nil && !delegate.rejected ? delegate.root : nil
    }
}
