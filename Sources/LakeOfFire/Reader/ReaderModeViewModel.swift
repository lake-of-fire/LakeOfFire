import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static var shared = ReaderViewModelActor()
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var processReadabilityContent: ((SwiftSoup.Document) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    
    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()
    
    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    private var contentRulesForReadabilityLoading = """
    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
        """
        {
             "trigger": {
                 "url-filter": ".*",
                 "resource-type": ["\($0)"]
             },
             "action": {
                 "type": "block"
             }
         }
        """
    } .joined(separator: ", "))
    ]
    """
    
    public func isReaderModeButtonBarVisible(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && !content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    func hideReaderModeButtonBar(content: (any ReaderContentProtocol)) async throws {
        if !content.isReaderModeOfferHidden {
            try await content.asyncWrite { _, content in
                content.isReaderModeOfferHidden = true
                content.refreshChangeMetadata(explicitlyModified: true)
            }
            objectWillChange.send()
        }
    }
    
    @MainActor
    internal func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        guard let readabilityContent else {
            isReaderModeLoading = false
            return
        }
        let contentURL = readerContent.pageURL
        isReaderModeLoading = true
        Task { @MainActor in
            guard contentURL == readerContent.pageURL else {
                isReaderModeLoading = false
                return
            }
            do {
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: readabilityContent,
                    renderToSelector: readabilityContainerSelector,
                    in: readabilityContainerFrameInfo,
                    scriptCaller: scriptCaller
                )
            } catch {
                print(error)
                isReaderModeLoading = false
            }
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    private func showReadabilityContent(readerContent: ReaderContent, readabilityContent: String, renderToSelector: String?, in frameInfo: WKFrameInfo?, scriptCaller: WebViewScriptCaller) async throws {
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            isReaderModeLoading = false
            return
        }
        let url = content.url
        
        Task {
            await scriptCaller.evaluateJavaScript("""
            if (document.body) {
                document.body.dataset.isNextLoadInReaderMode = 'true';
            }
            """)
        }
        
        try await content.asyncWrite { _, content in
            content.isReaderModeByDefault = true
            content.isReaderModeAvailable = false
            content.isReaderModeOfferHidden = false
            if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                if !url.isReaderFileURL && (content.content?.isEmpty ?? true) {
                    content.html = readabilityContent
                }
                if content.title.isEmpty {
                    content.title = content.html?.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.truncate(36) ?? ""
                }
                content.rssContainsFullContent = true
            }
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        
        if !isReaderMode {
            isReaderMode = true
        }
        
        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let processReadabilityContent = processReadabilityContent
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        
        try await { @ReaderViewModelActor [weak self] in
            var doc: SwiftSoup.Document
            doc = try await processForReaderMode(
                content: readabilityContent,
                url: url,
                contentSectionLocationIdentifier: nil,
                isEBook: false,
                defaultTitle: titleForDisplay,
                imageURL: imageURLToDisplay,
                injectEntryImageIntoHeader: injectEntryImageIntoHeader,
                defaultFontSize: defaultFontSize ?? 18
            )
            
            var html: String
            if let processReadabilityContent = processReadabilityContent {
                html = await processReadabilityContent(doc)
            } else {
                html = try doc.outerHtml()
            }
            let transformedContent = html
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    print("Readability content URL mismatch", url, readerContent.pageURL)
                    isReaderModeLoading = false
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    await scriptCaller.evaluateJavaScript(
                        """
                        var root = document.body
                        if (renderToSelector) {
                            root = document.querySelector(renderToSelector)
                        }
                        var serialized = html
                        
                        let xmlns = document.body?.getAttribute('xmlns')
                        if (xmlns) {
                            let parser = new DOMParser()
                            let doc = parser.parseFromString(serialized, 'text/html')
                            let readabilityNode = doc.body
                            let replacementNode = root.cloneNode()
                            replacementNode.innerHTML = ''
                            for (let innerNode of readabilityNode.childNodes) {
                                serialized = new XMLSerializer().serializeToString(innerNode)
                                replacementNode.innerHTML += serialized
                            }
                            root.innerHTML = replacementNode.innerHTML
                        } else if (root) {
                            root.outerHTML = serialized
                        }
                        
                        let style = document.createElement('style')
                        style.textContent = css
                        document.head.appendChild(style)
                        document.body?.classList.add('readability-mode')
                        """,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": Readability.shared.css,
                        ], in: frameInfo)
                } else {
                    navigator?.loadHTML(transformedContent, baseURL: url)
                }
                try await { @MainActor in
                    isReaderModeLoading = false
                }()
            }()
        }()
    }
    
    @MainActor
    public func onNavigationCommitted(readerContent: ReaderContent, newState: WebViewState, scriptCaller: WebViewScriptCaller) async throws {
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
        contentRules = nil
        
        guard let content = readerContent.content else {
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            isReaderModeLoading = false
            return
        }
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            isReaderModeLoading = false
            return
        }
        
        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = newState.pageURL.isEBookURL || content.isReaderModeByDefault
        if isReaderMode != isReaderModeVerified {
            withAnimation {
                isReaderModeLoading = isReaderModeVerified
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
        }

        if newState.pageURL.isReaderURLLoaderURL {
            if let readerFileManager = readerFileManager, var html = await content.htmlToDisplay(readerFileManager: readerFileManager) {
                let currentURL = readerContent.pageURL
                guard committedURL.matchesReaderURL(currentURL) else {
                    print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                    isReaderModeLoading = false
                    return
                }
                if html.range(of: "<body.*?class=['\"].*?readability-mode.*?['\"]>", options: .regularExpression) == nil, html.range(of: "<body.*?data-is-next-load-in-reader-mode=['\"]true['\"]>", options: .regularExpression) == nil {
                    // TODO: is this code path still used at all?
                    if let _ = html.range(of: "<body", options: .caseInsensitive) {
                        html = html.replacingOccurrences(of: "<body", with: "<body data-is-next-load-in-reader-mode='true' ", options: .caseInsensitive)
                    } else {
                        html = "<body data-is-next-load-in-reader-mode='true'>\n\(html)\n</html>"
                    }
                    // TODO: Fix content rules... images still load...
                    contentRules = contentRulesForReadabilityLoading
                    navigator?.loadHTML(html, baseURL: committedURL)
                    isReaderModeLoading = false
                } else {
                    readabilityContent = html
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                }
            } else {
                navigator?.load(URLRequest(url: committedURL))
            }
        } else {
            if content.isReaderModeByDefault {
                if content.isReaderModeAvailable {
                    contentRules = contentRulesForReadabilityLoading
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else {
                    isReaderModeLoading = false
                }
            }
        }
    }
    
    @MainActor
    public func onNavigationFinished() {
    }
    
    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        isReaderModeLoading = false
    }
}

public struct ReaderModeProcessorCacheKey: Encodable, Hashable {
    public let contentURL: URL
    public let sectionLocation: String?
    
    public enum CodingKeys: String, CodingKey {
        case contentURL
        case sectionLocation
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentURL, forKey: .contentURL)
        try container.encodeIfPresent(sectionLocation, forKey: .sectionLocation)
    }
}

public let readerModeProcessorCache = LRUFileCache<ReaderModeProcessorCacheKey, [UInt8]>(
    //public let ebookProcessorCache = LRUCache<ReaderModeProcessorCacheKey, [UInt8]>(
    namespace: "ReaderModeTextProcessor",
    //    totalCostLimit: 30_000_000,
    totalBytesLimit: 250_000_000,
    countLimit: 20_000
)

@inlinable
internal func range(of subArray: ArraySlice<UInt8>, in arraySlice: ArraySlice<UInt8>, startingAt start: ArraySlice<UInt8>.Index) -> Range<ArraySlice<UInt8>.Index>? {
    guard !subArray.isEmpty, start < arraySlice.endIndex else { return nil }
    let subCount = subArray.count
    // Ensure that we iterate within bounds.
    for i in start...(arraySlice.endIndex - subCount) {
        if arraySlice[i..<i+subCount] == subArray {
            return i..<i+subCount
        }
    }
    return nil
}

fileprivate func extractBlobUrls(from bytes: [UInt8]) -> [ArraySlice<UInt8>] {
    let prefixBytes = UTF8Arrays.blobColon
    let prefixBytesCount = prefixBytes.count
    let quote1: UInt8 = 0x22 // "
    let quote2: UInt8 = 0x27 // '
    let bytesCount = bytes.count
    var blobUrls: [ArraySlice<UInt8>] = []
    var i = 0
    
    while i < bytesCount {
        // Skip continuation bytes (i.e. bytes that are not the start of a new UTF-8 scalar)
        if (bytes[i] & 0b11000000) == 0b10000000 {
            i += 1
            continue
        }
        
        // Determine length of current UTF-8 character
        let charLen: Int
        if bytes[i] < 0x80 {
            charLen = 1
        } else if bytes[i] < 0xE0 {
            charLen = 2
        } else if bytes[i] < 0xF0 {
            charLen = 3
        } else {
            charLen = 4
        }
        
        // Check for prefix match.
        if i + prefixBytesCount <= bytesCount {
            var match = true
            for k in 0..<prefixBytesCount {
                if bytes[i + k] != prefixBytes[k] {
                    match = false
                    break
                }
            }
            if match {
                let urlStart = i + prefixBytesCount
                var j = urlStart
                // Scan until we hit a quote or the end of the bytes.
                while j < bytesCount {
                    // Make sure we are at a character boundary
                    if (bytes[j] & 0b11000000) == 0b10000000 {
                        j += 1
                        continue
                    }
                    // Break if we hit a quote character.
                    if bytes[j] == quote1 || bytes[j] == quote2 {
                        break
                    }
                    // Move j by the character length at this position.
                    let len: Int
                    if bytes[j] < 0x80 {
                        len = 1
                    } else if bytes[j] < 0xE0 {
                        len = 2
                    } else if bytes[j] < 0xF0 {
                        len = 3
                    } else {
                        len = 4
                    }
                    j += len
                }
                blobUrls.append(bytes[urlStart..<j])
                i = j
                continue
            }
        }
        i += charLen
    }
    return blobUrls
}

fileprivate func replaceBlobUrls(in htmlBytes: [UInt8], with blobUrls: [ArraySlice<UInt8>]) -> [UInt8] {
    let extractedBlobUrlSlices = extractBlobUrls(from: htmlBytes)
    
    // Only replace as many as the lesser of the two counts.
    let minCount = min(blobUrls.count, extractedBlobUrlSlices.count)
    
    // Work with an ArraySlice for performance.
    let workingSlice = htmlBytes[htmlBytes.startIndex..<htmlBytes.endIndex]
    var result = [UInt8]()
    var currentIndex = workingSlice.startIndex
    
    // For each replacement, search for the extracted blob URL slice in workingSlice starting from currentIndex.
    for i in 0..<minCount {
        if let rangeFound = range(of: extractedBlobUrlSlices[i], in: workingSlice, startingAt: currentIndex) {
            // Append everything before the found range.
            result.append(contentsOf: workingSlice[currentIndex..<rangeFound.lowerBound])
            // Append the replacement blob URL bytes.
            result.append(contentsOf: blobUrls[i])
            // Move currentIndex past the found blob URL.
            currentIndex = rangeFound.upperBound
        }
    }
    
    // Append the remainder of the bytes if any exists.
    if currentIndex < workingSlice.endIndex {
        result.append(contentsOf: workingSlice[currentIndex..<workingSlice.endIndex])
    }
    
    return result
}

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate func rewriteManabiReaderFontSizeStyle(in htmlBytes: [UInt8], newFontSize: Double) -> [UInt8] {
    // Convert the UTF8 bytes to a String.
    guard let html = String(bytes: htmlBytes, encoding: .utf8) else {
        return htmlBytes
    }
    
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    var updatedHtml: String
    let newFontSizeStr = "font-size: " + String(newFontSize) + "px"
    // If a font-size exists in the style, replace it.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let replacement = readerFontSizeStyleRegex.replacementString(
            for: firstMatch,
            in: html,
            offset: 0,
            template: "$1" + newFontSizeStr
        )
        updatedHtml = nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    else if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = newFontSizeStr + "; " + content
        let replacement = prefix + newContent + suffix
        updatedHtml = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    }
    else {
        updatedHtml = html
    }
    
    // Convert the updated HTML string back to UTF8 bytes.
    return Array(updatedHtml.utf8)
}

public func processForReaderMode(
    content: String,
    url: URL,
    contentSectionLocationIdentifier: String?,
    isEBook: Bool,
    defaultTitle: String?,
    imageURL: URL?,
    injectEntryImageIntoHeader: Bool,
    defaultFontSize: CGFloat
) throws -> SwiftSoup.Document {
       // TODO: font size and theme set elsewhere already..?
    let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? defaultFontSize
    let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
    let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black
 
    var updatedContent = content
    let cacheKey = ReaderModeProcessorCacheKey(contentURL: url, sectionLocation: contentSectionLocationIdentifier)
    if let cached = readerModeProcessorCache.value(forKey: cacheKey) {
        if isEBook {
            let blobs = extractBlobUrls(from: content.utf8Array)
            var updatedCache = replaceBlobUrls(in: cached, with: blobs)
            // TODO: Also overwrite the theme here
            updatedCache = rewriteManabiReaderFontSizeStyle(
                in: updatedCache,
                newFontSize: readerFontSize
            )
            updatedContent = String(decoding: updatedCache, as: UTF8.self)
        } else {
            updatedContent = String(decoding: cached, as: UTF8.self)
        }
    }
    
    let isXML = content.hasPrefix("<?xml")
    let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
    let doc = try SwiftSoup.parse(updatedContent, url.absoluteString, parser)
    doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
    
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if let oldElement = try doc.getElementsByClass("reader-content").first(), try doc.getElementById("reader-content") == nil {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }
    
    if isEBook {
        try doc.body()?.attr("data-is-ebook", "true")
    }
    
    if let bodyTag = doc.body() {
        var bodyStyle = "font-size: \(readerFontSize)px"
        if let existingBodyStyle = try? bodyTag.attr("style"), !existingBodyStyle.isEmpty {
            bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
        }
        _ = try? bodyTag.attr("style", bodyStyle)
        _ = try? bodyTag.attr("data-manabi-light-theme", lightModeTheme.rawValue)
        _ = try? bodyTag.attr("data-manabi-dark-theme", darkModeTheme.rawValue)
    }
    
    if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
        let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
        do {
            try existing.html(escapedTitle)
        } catch { }
    }
    do {
        try fixAnnoyingTitlesWithPipes(doc: doc)
    } catch { }
    
    if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
        do {
            try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
        } catch { }
    }
    
    if !isEBook {
        transformContentSpecificToFeed(doc: doc, url: url)
        do {
            try wireViewOriginalLinks(doc: doc, url: url)
        } catch { }
    }
    return doc
}
