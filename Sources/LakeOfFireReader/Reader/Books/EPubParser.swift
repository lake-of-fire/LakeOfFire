import Foundation
import LakeOfFireContent

struct EPubParser {
    private static let containerNamespace = "urn:oasis:names:tc:opendocument:xmlns:container"
    private static let packageNamespace = "http://www.idpf.org/2007/opf"
    private static let dublinCoreNamespace = "http://purl.org/dc/elements/1.1/"
    private static let packageMediaType = "application/oebps-package+xml"
    private static let metadataWhitespace = CharacterSet(charactersIn: "\t\n\u{000C}\r ")

    /// Reads metadata from either a packed or unpacked EPUB through the same
    /// package-entry boundary used by the viewer.
    static func parseMetadataAndCover(
        from epubURL: URL
    ) throws -> (title: String, author: String?, coverHref: String?, publicationDate: Date?)? {
        let source = try ReaderPackageEntrySource(localURL: epubURL)
        let containerData = try source.readEntry(subpath: "META-INF/container.xml")
        guard let packagePath = parseContainer(containerData) else { return nil }
        let packageData = try source.readEntry(subpath: packagePath)
        guard let metadata = parsePackageDocument(packageData) else { return nil }

        let packageDirectory = (packagePath as NSString).deletingLastPathComponent
        let coverHref = metadata.coverHref.flatMap {
            ReaderPackageEntrySource.resolveSubpath($0, relativeTo: packageDirectory)
        }
        return (
            title: metadata.title,
            author: metadata.author,
            coverHref: coverHref,
            publicationDate: metadata.publicationDate
        )
    }

    private static func normalizedNamespace(_ namespaceURI: String?) -> String? {
        guard let namespaceURI, !namespaceURI.isEmpty else { return nil }
        return namespaceURI
    }

    private static func normalizedMetadataText(_ value: String) -> String {
        value.components(separatedBy: metadataWhitespace)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Reduced-precision W3C dates map to the first UTC instant in their stated
    /// period because the library stores `Date` rather than source precision.
    private static func parsePublicationDate(_ value: String) -> Date? {
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

    /// Selects the first direct, correctly typed EPUB package document.
    private static func parseContainer(_ data: Data) -> String? {
        final class ContainerParser: NSObject, XMLParserDelegate {
            private var depth = 0
            private var hasValidContainerRoot = false
            private var containerNamespaceURI: String?
            private var rootfilesDepth: Int?
            var foundPath: String?

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                depth += 1
                let namespaceURI = EPubParser.normalizedNamespace(namespaceURI)
                if depth == 1 {
                    guard elementName == "container",
                          namespaceURI == nil || namespaceURI == EPubParser.containerNamespace else {
                        return
                    }
                    hasValidContainerRoot = true
                    containerNamespaceURI = namespaceURI
                    return
                }

                guard hasValidContainerRoot,
                      namespaceURI == containerNamespaceURI else {
                    return
                }
                if depth == 2, elementName == "rootfiles" {
                    rootfilesDepth = depth
                    return
                }
                guard foundPath == nil,
                      rootfilesDepth == 2,
                      depth == 3,
                      elementName == "rootfile",
                      attributeDict["media-type"] == EPubParser.packageMediaType,
                      let fullPath = attributeDict["full-path"],
                      !fullPath.isEmpty else {
                    return
                }
                foundPath = fullPath
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                if rootfilesDepth == depth, elementName == "rootfiles" {
                    rootfilesDepth = nil
                }
                depth = max(depth - 1, 0)
            }
        }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = ContainerParser()
        parser.delegate = delegate
        guard parser.parse(),
              parser.parserError == nil,
              let foundPath = delegate.foundPath else {
            return nil
        }
        return ReaderPackageEntrySource.resolveSubpath(foundPath, relativeTo: "")
    }

    /// Matches package nodes by namespace and direct-child depth so extension
    /// lookalikes cannot replace the primary metadata or manifest graph.
    private static func parsePackageDocument(
        _ data: Data
    ) -> (title: String, coverHref: String?, author: String?, publicationDate: Date?)? {
        final class PackageParser: NSObject, XMLParserDelegate {
            private enum TextField {
                case title
                case creator
                case date
            }

            private var depth = 0
            private var hasValidPackageRoot = false
            private var packageNamespaceURI: String?
            private var metadataDepth: Int?
            private var manifestDepth: Int?
            private var metadataCount = 0
            private var manifestCount = 0
            private var activeTextField: TextField?
            private var activeTextDepth: Int?
            private var accumulatingText = ""
            private var didSelectTitle = false
            private var didSelectCreator = false
            private var didSelectDate = false
            private var coverID: String?
            private var coverImageHref: String?
            private var manifestHrefsByID: [String: String] = [:]

            private(set) var foundTitle: String?
            private(set) var foundAuthor: String?
            private(set) var foundDate: Date?

            var hasCompletePackageGraph: Bool {
                hasValidPackageRoot && metadataCount == 1 && manifestCount == 1
            }

            var selectedCoverHref: String? {
                coverImageHref ?? coverID.flatMap { manifestHrefsByID[$0] }
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                depth += 1
                let namespaceURI = EPubParser.normalizedNamespace(namespaceURI)
                if depth == 1 {
                    guard elementName == "package",
                          namespaceURI == nil || namespaceURI == EPubParser.packageNamespace else {
                        return
                    }
                    hasValidPackageRoot = true
                    packageNamespaceURI = namespaceURI
                    return
                }

                guard hasValidPackageRoot else { return }
                if depth == 2,
                   namespaceURI == packageNamespaceURI,
                   elementName == "metadata" {
                    metadataCount += 1
                    if metadataCount == 1 {
                        metadataDepth = depth
                    }
                    return
                }
                if depth == 2,
                   namespaceURI == packageNamespaceURI,
                   elementName == "manifest" {
                    manifestCount += 1
                    if manifestCount == 1 {
                        manifestDepth = depth
                    }
                    return
                }

                if metadataDepth == 2, depth == 3 {
                    if namespaceURI == EPubParser.dublinCoreNamespace {
                        switch elementName {
                        case "title" where !didSelectTitle:
                            didSelectTitle = true
                            beginTextField(.title)
                        case "creator" where !didSelectCreator:
                            didSelectCreator = true
                            beginTextField(.creator)
                        case "date" where !didSelectDate:
                            didSelectDate = true
                            beginTextField(.date)
                        default:
                            break
                        }
                    } else if namespaceURI == packageNamespaceURI,
                              elementName == "meta",
                              coverID == nil,
                              attributeDict["name"]?.lowercased() == "cover",
                              let content = attributeDict["content"],
                              !content.isEmpty {
                        coverID = content
                    }
                    return
                }

                guard manifestDepth == 2,
                      depth == 3,
                      namespaceURI == packageNamespaceURI,
                      elementName == "item",
                      let href = attributeDict["href"],
                      !href.isEmpty else {
                    return
                }
                if let id = attributeDict["id"],
                   !id.isEmpty,
                   manifestHrefsByID[id] == nil {
                    manifestHrefsByID[id] = href
                }
                if coverImageHref == nil,
                   attributeDict["properties"]?
                    .split(whereSeparator: \.isWhitespace)
                    .contains("cover-image") == true {
                    coverImageHref = href
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if activeTextField != nil {
                    accumulatingText += string
                }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                let namespaceURI = EPubParser.normalizedNamespace(namespaceURI)
                if activeTextDepth == depth,
                   namespaceURI == EPubParser.dublinCoreNamespace {
                    switch (activeTextField, elementName) {
                    case (.title, "title"), (.creator, "creator"), (.date, "date"):
                        finishTextField()
                    default:
                        break
                    }
                }
                if metadataDepth == depth,
                   namespaceURI == packageNamespaceURI,
                   elementName == "metadata" {
                    metadataDepth = nil
                }
                if manifestDepth == depth,
                   namespaceURI == packageNamespaceURI,
                   elementName == "manifest" {
                    manifestDepth = nil
                }
                depth = max(depth - 1, 0)
            }

            private func beginTextField(_ field: TextField) {
                activeTextField = field
                activeTextDepth = depth
                accumulatingText = ""
            }

            private func finishTextField() {
                let normalized = EPubParser.normalizedMetadataText(accumulatingText)
                switch activeTextField {
                case .title:
                    if !normalized.isEmpty { foundTitle = normalized }
                case .creator:
                    if !normalized.isEmpty { foundAuthor = normalized }
                case .date:
                    if !normalized.isEmpty {
                        foundDate = EPubParser.parsePublicationDate(normalized)
                    }
                case nil:
                    break
                }
                activeTextField = nil
                activeTextDepth = nil
                accumulatingText = ""
            }
        }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = PackageParser()
        parser.delegate = delegate
        guard parser.parse(),
              parser.parserError == nil,
              delegate.hasCompletePackageGraph,
              let title = delegate.foundTitle else {
            return nil
        }
        return (
            title: title,
            coverHref: delegate.selectedCoverHref,
            author: delegate.foundAuthor,
            publicationDate: delegate.foundDate
        )
    }
}
