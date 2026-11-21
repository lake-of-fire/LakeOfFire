import Foundation
import CoreText
import LakeOfFireContent
import LakeOfFireCore

public struct SharedReaderFontAsset: Hashable, Sendable {
    public let localFileURL: URL?
    public let systemFontNames: [String: String]
    public let enablesRuntimeResourceDelivery: Bool
    public let mimeType: String
    public let format: String
    public let horizontalFamilyName: String
    public let verticalFamilyName: String
    public let publicFilenameBase: String

    public init(
        localFileURL: URL,
        mimeType: String,
        format: String,
        horizontalFamilyName: String,
        verticalFamilyName: String,
        publicFilenameBase: String = "YuKyokasho"
    ) {
        self.systemFontNames = [:]
        self.enablesRuntimeResourceDelivery = false
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.format = format
        self.horizontalFamilyName = horizontalFamilyName
        self.verticalFamilyName = verticalFamilyName
        self.publicFilenameBase = publicFilenameBase
    }

    /// Name-only by default. Opt in to serve validated, exact CoreText resources
    /// through the reader's local schemes, resolving them anew for each request.
    public init(
        systemFontNames: [String: String],
        horizontalFamilyName: String,
        verticalFamilyName: String,
        enablesRuntimeResourceDelivery: Bool = false
    ) {
        self.localFileURL = nil
        self.systemFontNames = systemFontNames
        self.enablesRuntimeResourceDelivery = enablesRuntimeResourceDelivery
        self.mimeType = "text/css"
        self.format = ""
        self.horizontalFamilyName = horizontalFamilyName
        self.verticalFamilyName = verticalFamilyName
        self.publicFilenameBase = "system-font"
    }

    public var supportedFamilyNames: [String] {
        horizontalFamilyName == verticalFamilyName
            ? [horizontalFamilyName]
            : [horizontalFamilyName, verticalFamilyName]
    }

    public var publicFilename: String {
        let fileExtension = localFileURL?.pathExtension ?? ""
        if fileExtension.isEmpty {
            return publicFilenameBase
        }
        return publicFilenameBase + "." + fileExtension
    }

    public func supportsFamily(_ familyName: String) -> Bool {
        supportedFamilyNames.contains(familyName)
    }

    public func cssFontFaceFamilyName(for familyName: String) -> String {
        guard enablesRuntimeResourceDelivery, systemFontNames[familyName] != nil else { return familyName }
        // An @font-face with the installed family name hides the platform face.
        return "Manabi Reader \(familyName)"
    }

    public func cssFontFamilyList(for familyName: String) -> String {
        let routedFamily = cssFontFaceFamilyName(for: familyName)
        if routedFamily == familyName { return "'\(familyName)'" }
        return "'\(routedFamily)', '\(familyName)'"
    }
}


/// Publishes the existing installation's dependency before a native CSS provider
/// can suspend. Completion is still fenced by this exact receipt and document.
public let sharedReaderFontSourcePreparationJavaScript = #"""
(function(sourceID, revision) {
    const root = document.documentElement;
    if (!root || BigInt(String(revision)) < BigInt(String(globalThis.manabiReaderFontAvailabilityRevision || '0'))) return false;
    const previous = globalThis.manabiReaderFontStyleInstallation;
    let resolve;
    const previousStylesheet = previous?.stylesheet?.sourceID
        ? previous.stylesheet.previousStylesheet : previous?.stylesheet;
    const receipt = { sourceID, revision, root, previousStylesheet, state: 'pending',
        ready: new Promise(done => { resolve = done; }) };
    const settle = state => {
        if (receipt.state !== 'pending') return;
        receipt.state = state;
        window.removeEventListener('pagehide', cancelled);
        resolve(state);
    };
    const cancelled = () => settle('cancelled');
    receipt.cancel = cancelled;
    receipt.complete = settle;
    const installation = { stylesheet: receipt };
    globalThis.manabiReaderFontStyleInstallation = installation;
    window.addEventListener('pagehide', cancelled, { once: true });
    // Retire another source attempt, but keep a valid physical sheet alive
    // while the replacement provider is deciding whether it has CSS at all.
    if (previous?.stylesheet?.sourceID) previous.stylesheet.cancel();
    return true;
})
"""#

/// Emitted by both reader font installers. A receipt describes one physical
/// stylesheet request; it grants no document or reading-progress authority.
public let sharedReaderFontStylesheetInstallerJavaScript = #"""
(function installReaderFontStylesheet(installation, previousInstallation, style, href) {
    const root = document.documentElement;
    const previous = previousInstallation?.stylesheet;
    installation.installStylesheet = (nextStyle, nextHref) => {
        if (globalThis.manabiReaderFontStyleInstallation !== installation
            || document.documentElement !== root) return null;
        return installReaderFontStylesheet(installation, installation, nextStyle, nextHref);
    };
    let receipt = style.__manabiReaderFontStylesheetReceipt;
    if (!receipt || receipt.root !== root || receipt.href !== href
        || style.href !== href || receipt.state === 'cancelled') {
        receipt?.cancel();
        let resolve;
        receipt = { root, style, href, state: 'pending',
            ready: new Promise(done => { resolve = done; }) };
        const settle = state => {
            if (receipt.state !== 'pending') return;
            receipt.state = state;
            style.removeEventListener('load', loaded);
            style.removeEventListener('error', failed);
            window.removeEventListener('pagehide', cancelled);
            resolve(state);
        };
        const current = () => style.__manabiReaderFontStylesheetReceipt === receipt
            && document.documentElement === root && style.href === href;
        const loaded = () => settle(current() ? 'loaded' : 'cancelled');
        const failed = () => settle(current() ? 'failed' : 'cancelled');
        const cancelled = () => settle('cancelled');
        receipt.cancel = cancelled;
        style.__manabiReaderFontStylesheetReceipt = receipt;
        installation.stylesheet = receipt;
        try {
            style.addEventListener('load', loaded);
            style.addEventListener('error', failed);
            window.addEventListener('pagehide', cancelled, { once: true });
            if (style.href === href && style.sheet) settle('loaded');
            else if (style.href !== href) style.href = href;
        } catch (_) { settle('failed'); }
    }
    installation.stylesheet = receipt;
    if (previous && previous !== receipt) previous.cancel();
    return receipt;
})
"""#

// The endpoint encodes logical identity only, never a filesystem path. Each
// registered PostScript name retains its route across downloads and file changes.
private func sharedReaderFontRuntimeFilename(postScriptName: String) -> String {
    let encodedName = Data(postScriptName.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "system-" + encodedName
}

private func sharedReaderFontRuntimeResource(
    postScriptName: String
) -> (url: URL, mimeType: String)? {
    let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
    guard CTFontCopyPostScriptName(font) as String == postScriptName,
          let resourceURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
          resourceURL.isFileURL else { return nil }
    let fileURL = resourceURL.resolvingSymlinksInPath()
    guard fileURL.isFileURL,
          FileManager.default.isReadableFile(atPath: fileURL.path) else { return nil }
    let mimeType: String
    switch fileURL.pathExtension.lowercased() {
    case "ttf":
        mimeType = "font/ttf"
    case "otf":
        mimeType = "font/otf"
    case "ttc", "otc":
        mimeType = "font/collection"
    default:
        return nil
    }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
          descriptors.contains(where: {
              CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == postScriptName
          }) else { return nil }
    return (fileURL, mimeType)
}

public struct SharedReaderFontServedResponse {
    public let response: HTTPURLResponse
    public let data: Data

    public init(response: HTTPURLResponse, data: Data) {
        self.response = response
        self.data = data
    }
}

public enum SharedReaderFontInjectionMode: String, Equatable, Sendable {
    case localScheme
    case blob
}

public enum SharedReaderFontScheme: String, Sendable {
    case ebook
    case internalLocal = "internal"
    case readerFile = "reader-file"

    init?(pageURL: URL) {
        guard let scheme = pageURL.scheme?.lowercased() else { return nil }
        switch scheme {
        case "ebook":
            self = .ebook
        case "internal":
            guard pageURL.host == "local" else { return nil }
            self = .internalLocal
        case "reader-file":
            self = .readerFile
        default:
            return nil
        }
    }

    var host: String {
        switch self {
        case .ebook:
            return "ebook"
        case .internalLocal:
            return "local"
        case .readerFile:
            return "file"
        }
    }

    var stylesheetPath: String {
        switch self {
        case .ebook:
            return "/load/manabi-fonts.css"
        case .internalLocal, .readerFile:
            return "/manabi-fonts.css"
        }
    }

    var fontPathPrefix: String {
        switch self {
        case .ebook:
            return "/load/manabi-fonts/"
        case .internalLocal, .readerFile:
            return "/manabi-fonts/"
        }
    }
}

private func sharedReaderFontBaseURL(for pageURL: URL) -> URL? {
    if let scheme = pageURL.scheme?.lowercased(), scheme != "blob" {
        return pageURL
    }
    let absoluteString = pageURL.absoluteString
    guard absoluteString.hasPrefix("blob:") else { return pageURL }
    let underlyingURLString = String(absoluteString.dropFirst("blob:".count))
    return URL(string: underlyingURLString)
}

public enum SharedReaderFontRoute: Equatable, Sendable {
    case stylesheet(familyName: String)
    case font
}

public func sharedReaderFontUsesLocalScheme(for pageURL: URL) -> Bool {
    guard let baseURL = sharedReaderFontBaseURL(for: pageURL) else { return false }
    return SharedReaderFontScheme(pageURL: baseURL) != nil
}

public func sharedReaderFontInjectionMode(for pageURL: URL) -> SharedReaderFontInjectionMode {
    sharedReaderFontUsesLocalScheme(for: pageURL) ? .localScheme : .blob
}

public func sharedReaderFontStylesheetURL(for pageURL: URL, familyName: String) -> URL? {
    guard let baseURL = sharedReaderFontBaseURL(for: pageURL),
          let scheme = SharedReaderFontScheme(pageURL: baseURL) else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = scheme.host
    components.path = scheme.stylesheetPath
    components.queryItems = [.init(name: "family", value: familyName)]
    return components.url
}

public func sharedReaderFontStylesheetURLTemplate(for pageURL: URL) -> String? {
    sharedReaderFontStylesheetURL(for: pageURL, familyName: "__MANABI_FONT_FAMILY__")?.absoluteString
}

private func sharedReaderFontFontURL(
    for pageURL: URL,
    asset: SharedReaderFontAsset,
    postScriptName: String? = nil
) -> URL? {
    guard let baseURL = sharedReaderFontBaseURL(for: pageURL),
          let scheme = SharedReaderFontScheme(pageURL: baseURL) else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = scheme.host
    if let postScriptName {
        components.path = scheme.fontPathPrefix + sharedReaderFontRuntimeFilename(postScriptName: postScriptName)
        components.fragment = postScriptName
        components.queryItems = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "revision" }
    } else {
        components.path = scheme.fontPathPrefix + asset.publicFilename
    }
    return components.url
}

public func sharedReaderFontRoute(
    for requestURL: URL,
    asset: SharedReaderFontAsset?
) -> SharedReaderFontRoute? {
    guard let scheme = SharedReaderFontScheme(pageURL: requestURL) else { return nil }
    if requestURL.path == scheme.stylesheetPath {
        let familyName = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "family" })?
            .value ?? ""
        return .stylesheet(familyName: familyName)
    }
    if let asset, requestURL.path == scheme.fontPathPrefix + asset.publicFilename {
        return .font
    }
    if requestURL.path.hasPrefix(scheme.fontPathPrefix) {
        return .font
    }
    return nil
}

private func sharedReaderFontHTTPResponse(
    url: URL,
    statusCode: Int,
    contentType: String,
    textEncodingName: String? = nil,
    extraHeaders: [String: String] = [:]
) -> HTTPURLResponse {
    var headers = extraHeaders
    headers["Content-Type"] = contentType
    return HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    ) ?? HTTPURLResponse(
        url: url,
        mimeType: contentType,
        expectedContentLength: 0,
        textEncodingName: textEncodingName
    )
}

/// Substituted when a blob stylesheet is attached to a specific Reader revision.
public let sharedReaderFontRevisionPlaceholder = "__MANABI_READER_FONT_REVISION__"

/// The font-face rules used by the reader and its settings preview.
/// The source URL supplies the reader scheme and the current availability revision.
public func sharedReaderFontFaceCSS(for sourceURL: URL, asset: SharedReaderFontAsset) -> String? {
    var rules: [String] = []
    for family in asset.supportedFamilyNames {
        let source: String
        if let postScriptName = asset.systemFontNames[family] {
            let local = "local('\(postScriptName)')"
            if asset.enablesRuntimeResourceDelivery {
                guard let url = sharedReaderFontFontURL(
                    for: sourceURL, asset: asset, postScriptName: postScriptName
                ) else { return nil }
                source = "url(\"\(url.absoluteString)\"), \(local)"
            } else {
                source = local
            }
        } else {
            guard let url = sharedReaderFontFontURL(for: sourceURL, asset: asset) else { return nil }
            source = "url(\"\(url.absoluteString)\") format(\"\(asset.format)\")"
        }
        rules.append("""
        @font-face {
          font-family: '\(asset.cssFontFaceFamilyName(for: family))';
          font-weight: 400 700;
          font-style: normal;
          src: \(source);
          font-display: swap;
        }
        """)
    }
    return rules.joined(separator: "\n")
}

/// Supplies system-managed font files for a native-generated Reader document.
/// Each collection is read once even when both faces refer to the same file.
public func sharedReaderFontDocumentResources(
    asset: SharedReaderFontAsset, sourceURL: URL, stylesheet: String
) -> [(base64: String, mimeType: String, sourceURLs: [String])] {
    guard asset.enablesRuntimeResourceDelivery else { return [] }
    var files: [URL: (mimeType: String, sourceURLs: [String])] = [:]
    for postScriptName in Set(asset.systemFontNames.values) {
        guard let source = sharedReaderFontFontURL(for: sourceURL, asset: asset, postScriptName: postScriptName),
              stylesheet.contains(source.absoluteString),
              let file = sharedReaderFontRuntimeResource(postScriptName: postScriptName) else { continue }
        files[file.url, default: (file.mimeType, [])].sourceURLs.append(source.absoluteString)
    }
    return files.compactMap { fileURL, resource in
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return (data.base64EncodedString(), resource.mimeType, resource.sourceURLs)
    }
}

public func sharedReaderFontResponse(
    for requestURL: URL,
    asset: SharedReaderFontAsset?
) -> SharedReaderFontServedResponse? {
    guard let route = sharedReaderFontRoute(for: requestURL, asset: asset) else { return nil }
    guard let asset else {
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 404,
            contentType: "text/plain",
            textEncodingName: "utf-8"
        )
        return SharedReaderFontServedResponse(response: response, data: Data())
    }

    switch route {
    case .stylesheet(let familyName):
        guard asset.supportsFamily(familyName),
              let fontFaces = sharedReaderFontFaceCSS(for: requestURL, asset: asset) else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8"
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }

        let css = """
        \(fontFaces)
        :root {
          --mnb-content-font: \(asset.cssFontFamilyList(for: asset.horizontalFamilyName));
          --mnb-content-vertical-font: \(asset.cssFontFamilyList(for: asset.verticalFamilyName));
        }
        html,
        body,
        body *:not(.mnb-tracking-container):not(.mnb-tracking-container *):not(#page-tracking-container):not(#page-tracking-container *):not(#nav-hidden-buttons):not(#nav-hidden-buttons *):not(#nav-bar):not(#nav-bar *):not(rt) {
          font-family: var(--mnb-content-font, \(asset.cssFontFamilyList(for: asset.horizontalFamilyName))), system-ui !important;
        }
        body.reader-vertical-writing,
        body.reader-vertical-writing *:not(.mnb-tracking-container):not(.mnb-tracking-container *):not(#page-tracking-container):not(#page-tracking-container *):not(#nav-hidden-buttons):not(#nav-hidden-buttons *):not(#nav-bar):not(#nav-bar *):not(rt) {
          font-family: var(--mnb-content-vertical-font, \(asset.cssFontFamilyList(for: asset.verticalFamilyName))), system-ui !important;
        }
        rt {
          font-family: -apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', system-ui, sans-serif !important;
        }
        """
        let data = Data(css.utf8)
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 200,
            contentType: "text/css",
            textEncodingName: "utf-8"
        )
        return SharedReaderFontServedResponse(response: response, data: data)

    case .font:
        let fileURL: URL?
        let mimeType: String
        let scheme = SharedReaderFontScheme(pageURL: requestURL)
        if let scheme, let localFileURL = asset.localFileURL,
           requestURL.path == scheme.fontPathPrefix + asset.publicFilename {
            fileURL = localFileURL
            mimeType = asset.mimeType
        } else if let scheme, asset.enablesRuntimeResourceDelivery,
                  let postScriptName = asset.systemFontNames.values.first(where: {
                      requestURL.path == scheme.fontPathPrefix + sharedReaderFontRuntimeFilename(postScriptName: $0)
                  }),
                  let resource = sharedReaderFontRuntimeResource(postScriptName: postScriptName) {
            fileURL = resource.url
            mimeType = resource.mimeType
        } else {
            fileURL = nil
            mimeType = "text/plain"
        }
        // Prefix routing catches unknown font endpoints, but only the exact
        // registered routes above can ever produce bytes.
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8",
                extraHeaders: ["Cache-Control": "no-store"]
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 200,
            contentType: mimeType,
            extraHeaders: ["Access-Control-Allow-Origin": "*"]
        )
        return SharedReaderFontServedResponse(response: response, data: data)
    }
}
