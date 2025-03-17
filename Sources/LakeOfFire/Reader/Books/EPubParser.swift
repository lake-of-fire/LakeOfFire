import Foundation
import ZIPFoundation

struct EPubParser {
    /// Parses the EPUB file at the given URL (either a ZIP archive with an epub extension or an unpacked EPUB directory)
    /// and returns a tuple with the book title and cover image relative path.
    /// Returns nil if parsing fails.
    static func parseMetadataAndCover(from epubURL: URL) throws -> (title: String, coverHref: String)? {
        let opfData: Data?
        let fileManager = FileManager.default
        
        if fileManager.isDirectory(epubURL) {
            // Unpacked EPUB directory.
            let containerURL = epubURL.appendingPathComponent("META-INF/container.xml")
            guard let containerData = try? Data(contentsOf: containerURL),
                  let opfRelativePath = parseContainer(containerData) else { return nil }
            let opfURL = epubURL.appendingPathComponent(opfRelativePath)
            opfData = try? Data(contentsOf: opfURL)
        } else {
            // EPUB is stored as a ZIP archive.
            guard let archive = Archive(url: epubURL, accessMode: .read) else { return nil }
            guard let containerEntry = archive["META-INF/container.xml"] else { return nil }
            var containerData = Data()
            try archive.extract(containerEntry) { containerData.append($0) }
            guard let opfRelativePath = parseContainer(containerData),
                  let opfEntry = archive[opfRelativePath] else { return nil }
            var opfDataLocal = Data()
            try archive.extract(opfEntry) { opfDataLocal.append($0) }
            opfData = opfDataLocal
        }
        
        guard let data = opfData else { return nil }
        return parseOPF(data)
    }
    
    // MARK: - Internal Parsing Helpers
    
    /// Parses the container.xml data to retrieve the “full-path” attribute of the first <rootfile>.
    private static func parseContainer(_ data: Data) -> String? {
        final class ContainerParser: NSObject, XMLParserDelegate {
            var foundPath: String?
            func parser(_ parser: XMLParser,
                        didStartElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                if elementName == "rootfile", let fullPath = attributeDict["full-path"] {
                    foundPath = fullPath
                    parser.abortParsing()  // Stop parsing after finding the path.
                }
            }
            
            func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
                print("Container parse error: \(parseError)")
            }
        }
        
        let parser = XMLParser(data: data)
        let delegate = ContainerParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.foundPath
    }
    
    /// Parses the OPF XML data to extract both the book title and the cover image href.
    /// For EPUB v2, it looks for a meta element with name="cover" and then finds the corresponding <item> in the manifest.
    /// For EPUB v3, it looks for an <item> with a properties attribute containing "cover-image".
    private static func parseOPF(_ data: Data) -> (title: String, coverHref: String)? {
        final class OPFParserDelegate: NSObject, XMLParserDelegate {
            var epubVersion: String = "2.0"  // Default to EPUB 2.
            var foundCoverId: String?
            var coverHref: String?
            var foundTitle: String?
            var currentElement: String?
            var accumulatingTitle: String = ""
            var inMetadata = false
            var inManifest = false
            
            func parser(_ parser: XMLParser,
                        didStartElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?,
                        attributes attributeDict: [String : String] = [:]) {
                if elementName == "package" {
                    if let version = attributeDict["version"] {
                        epubVersion = version
                    }
                } else if elementName == "metadata" {
                    inMetadata = true
                } else if elementName == "manifest" {
                    inManifest = true
                }
                
                if inMetadata {
                    if elementName == "dc:title" {
                        currentElement = "dc:title"
                        accumulatingTitle = ""
                    }
                    // EPUB v2: capture the cover id from a meta element.
                    if epubVersion.hasPrefix("2") && elementName == "meta" {
                        if let name = attributeDict["name"], name.lowercased() == "cover",
                           let content = attributeDict["content"] {
                            foundCoverId = content
                        }
                    }
                }
                
                if inManifest && elementName == "item" {
                    // EPUB v3: look for an item with properties containing "cover-image".
                    if epubVersion.hasPrefix("3"),
                       let properties = attributeDict["properties"],
                       properties.contains("cover-image"),
                       let href = attributeDict["href"] {
                        coverHref = href
                    }
                    // EPUB v2: match the cover id with the manifest item id.
                    if epubVersion.hasPrefix("2"),
                       let coverId = foundCoverId,
                       let id = attributeDict["id"],
                       id == coverId,
                       let href = attributeDict["href"] {
                        coverHref = href
                    }
                }
            }
            
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if currentElement == "dc:title" {
                    accumulatingTitle += string
                }
            }
            
            func parser(_ parser: XMLParser, didEndElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?) {
                if elementName == "metadata" {
                    inMetadata = false
                }
                if elementName == "manifest" {
                    inManifest = false
                }
                if elementName == "dc:title" && currentElement == "dc:title" {
                    foundTitle = accumulatingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentElement = nil
                }
            }
            
            func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
                print("OPF parse error: \(parseError)")
            }
        }
        
        let parser = XMLParser(data: data)
        let delegate = OPFParserDelegate()
        parser.delegate = delegate
        parser.parse()
        
        if let title = delegate.foundTitle, let cover = delegate.coverHref {
            return (title: title, coverHref: cover)
        }
        return nil
    }
}

extension FileManager {
    /// Returns true if the URL points to a directory.
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return false
    }
}
