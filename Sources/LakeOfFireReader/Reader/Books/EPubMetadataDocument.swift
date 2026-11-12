import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The XML part of EPUB enrichment. Package I/O and its byte budgets stay in
/// EPubParser; these value-only decoders never publish a partially parsed file.
enum EPubMetadataDocument {
    struct Metadata: Equatable, Sendable {
        let title: String
        let author: String?
        let coverHref: String?
        let publicationDate: Date?
    }

    private static let opfNamespace = "http://www.idpf.org/2007/opf"
    private static let containerNamespace = "urn:oasis:names:tc:opendocument:xmlns:container"
    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"

    static func containerPath(_ data: Data) throws -> String? {
        let delegate = ContainerDelegate()
        guard try parse(data, delegate: delegate) else { return nil }
        return delegate.path
    }

    static func metadata(_ data: Data) throws -> Metadata? {
        let delegate = MetadataDelegate()
        guard try parse(data, delegate: delegate),
              delegate.hasCompletePackageGraph,
              let title = delegate.preferredTitle else { return nil }
        return Metadata(
            title: title,
            author: delegate.authors.first,
            coverHref: delegate.coverHref ?? delegate.coverID.flatMap { delegate.items[$0] },
            publicationDate: delegate.date
        )
    }

    private static func parse(_ data: Data, delegate: DocumentDelegate) throws -> Bool {
        try Task.checkCancellation()
        // Bound direct callers too. This is the existing metadata entry budget.
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let completed = parser.parse()
        try Task.checkCancellation()
        return completed && !delegate.failed && delegate.stack.isEmpty
    }

    /// Hrefs are URI references, whereas the result is a literal package entry
    /// name. Decode each component exactly once, then resolve contained '..'.
    static func coverPath(baseDirectory: String, href: String) -> String? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("/"), !href.contains("\\"),
              let uri = URLComponents(string: href), uri.scheme == nil, uri.host == nil else {
            return nil
        }
        let rawPath = String(href.prefix { $0 != "?" && $0 != "#" })
        guard !rawPath.isEmpty else { return nil }
        var components = baseDirectory.split(separator: "/").map(String.init)
        guard components.allSatisfy({ validComponent($0) && $0 != "." && $0 != ".." }) else {
            return nil
        }
        for raw in rawPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let component = String(raw).removingPercentEncoding,
                  validComponent(component) else { return nil }
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private struct Element: Equatable {
        let name: String
        let namespace: String
    }

    private class DocumentDelegate: NSObject, XMLParserDelegate {
        var stack: [Element] = []
        var failed = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard !Task.isCancelled, stack.count < 128 else {
                failed = true
                parser.abortParsing()
                return
            }
            stack.append(Element(name: elementName, namespace: namespaceURI ?? ""))
            start(attributeDict)
        }

        func start(_ attributes: [String: String]) {}
        func end() {}
        func text(_ value: String) {}

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard !stack.isEmpty else { failed = true; return }
            end()
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let value = String(data: CDATABlock, encoding: .utf8) else {
                failed = true
                parser.abortParsing()
                return
            }
            text(value)
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

        // Metadata does not need DTD entities. Do not permit entity expansion
        // to turn a bounded input into an unbounded string or external read.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failed = true
            parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            failed = true
            parser.abortParsing()
        }

        func matches(_ names: [String], namespace: String) -> Bool {
            guard stack.map(\.name) == names, let rootNamespace = stack.first?.namespace,
                  rootNamespace.isEmpty || rootNamespace == namespace else { return false }
            // Retain historical namespace-less packages, but don't accept a
            // foreign nested element just because it has a familiar local name.
            return stack.allSatisfy { $0.namespace == rootNamespace }
        }
    }

    private final class ContainerDelegate: DocumentDelegate {
        var path: String?
        override func start(_ attributes: [String: String]) {
            guard path == nil,
                  matches(["container", "rootfiles", "rootfile"], namespace: containerNamespace),
                  attributes["media-type"] == "application/oebps-package+xml",
                  let value = attributes["full-path"], !value.isEmpty else { return }
            path = value
        }
    }

    private final class MetadataDelegate: DocumentDelegate {
        private struct Capture {
            let name: String
            let depth: Int
            let id: String?
            var value = ""
        }
        var titles: [(id: String?, value: String)] = []
        private var mainTitleIDs = Set<Data>()
        var preferredTitle: String? {
            titles.first(where: { $0.id.map { mainTitleIDs.contains(Data($0.utf8)) } == true })?.value
                ?? titles.first?.value
        }
        var authors: [String] = []
        var date: Date?
        var coverID: String?
        var coverHref: String?
        var items: [String: String] = [:]
        private var capture: Capture?
        private var metadataCount = 0
        private var manifestCount = 0
        private var didSelectDate = false

        var hasCompletePackageGraph: Bool { metadataCount == 1 && manifestCount == 1 }

        override func start(_ attributes: [String: String]) {
            guard let element = stack.last else { return }
            if matches(["package", "metadata"], namespace: opfNamespace) { metadataCount += 1 }
            if matches(["package", "manifest"], namespace: opfNamespace) { manifestCount += 1 }
            if stack.count == 3, element.namespace == dcNamespace,
               ["title", "creator", "date"].contains(element.name) {
                let parent = Array(stack.dropLast())
                if parent.map(\.name) == ["package", "metadata"],
                   let namespace = parent.first?.namespace,
                   namespace.isEmpty || namespace == opfNamespace,
                   parent.allSatisfy({ $0.namespace == namespace }) {
                    if element.name == "date" {
                        guard !didSelectDate else { return }
                        didSelectDate = true
                    }
                    capture = Capture(name: element.name, depth: stack.count, id: attributes["id"])
                }
            }
            if matches(["package", "metadata", "meta"], namespace: opfNamespace),
               attributes["property"] == "title-type",
               let refines = attributes["refines"], refines.hasPrefix("#"),
               let titleID = String(refines.dropFirst()).removingPercentEncoding,
               !titleID.isEmpty {
                // refines is a URL reference; XML parsing does not decode its
                // fragment. Decode once and retain the XML ID's exact spelling.
                capture = Capture(name: "title-type", depth: stack.count, id: titleID)
            }
            if matches(["package", "metadata", "meta"], namespace: opfNamespace),
               attributes["name"]?.lowercased() == "cover", coverID == nil {
                coverID = attributes["content"]
            }
            if matches(["package", "manifest", "item"], namespace: opfNamespace),
               let href = attributes["href"] {
                if let id = attributes["id"], items[id] == nil { items[id] = href }
                let tokens = (attributes["properties"] ?? "").split {
                    $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
                }
                if coverHref == nil, tokens.contains("cover-image") { coverHref = href }
            }
        }

        override func text(_ value: String) { capture?.value += value }

        override func end() {
            guard let capture, capture.depth == stack.count else { return }
            let value = capture.value.components(separatedBy: CharacterSet(charactersIn: "\t\n\u{000C}\r "))
                .filter { !$0.isEmpty }.joined(separator: " ")
            if !value.isEmpty {
                switch capture.name {
                case "title": titles.append((capture.id, value))
                case "title-type":
                    if value == "main", let id = capture.id { mainTitleIDs.insert(Data(id.utf8)) }
                case "creator": authors.append(value)
                case "date": if date == nil { date = parseDate(value) }
                default: break
                }
            }
            self.capture = nil
        }

        /// Reduced precision dates use the first UTC instant in the stated period.
        private func parseDate(_ value: String) -> Date? {
            let fractionalDateTime = ISO8601DateFormatter()
            fractionalDateTime.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalDateTime.date(from: value) {
                return date
            }

            let secondDateTime = ISO8601DateFormatter()
            secondDateTime.formatOptions = [.withInternetDateTime]
            if let date = secondDateTime.date(from: value) {
                return date
            }

            if value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$"#,
                options: .regularExpression
            ) != nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.isLenient = false
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
                if let date = formatter.date(from: value) {
                    return date
                }
            }

            let components = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...3).contains(components.count),
                  components[0].count == 4,
                  components.dropFirst().allSatisfy({ $0.count == 2 }),
                  components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let year = Int(components[0]),
                  year > 0 else {
                return nil
            }

            let month = components.count >= 2 ? Int(components[1]) : 1
            let day = components.count == 3 ? Int(components[2]) : 1
            guard let month, let day else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let expected = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day
            )
            guard let date = calendar.date(from: expected) else { return nil }
            let actual = calendar.dateComponents([.year, .month, .day], from: date)
            guard actual.year == year,
                  actual.month == month,
                  actual.day == day else {
                return nil
            }
            return date
        }
    }
}
