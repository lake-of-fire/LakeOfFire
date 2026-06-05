import Foundation

private func sharedReaderFontLog(
    _ stage: String,
    _ metadata: [String: String] = [:]
) {
    _ = stage
    _ = metadata
}

public struct SharedReaderFontAsset: Equatable, Sendable {
    public let localFileURL: URL
    public let mimeType: String
    public let format: String
    public let supportedFamilyNames: [String]
    public let publicFilenameBase: String

    public init(
        localFileURL: URL,
        mimeType: String,
        format: String,
        supportedFamilyNames: [String],
        publicFilenameBase: String = "YuKyokasho"
    ) {
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.format = format
        self.supportedFamilyNames = supportedFamilyNames
        self.publicFilenameBase = publicFilenameBase
    }

    public var publicFilename: String {
        let fileExtension = localFileURL.pathExtension
        if fileExtension.isEmpty {
            return publicFilenameBase
        }
        return publicFilenameBase + "." + fileExtension
    }

    public func supportsFamily(_ familyName: String) -> Bool {
        supportedFamilyNames.contains(familyName)
    }
}

public struct SharedReaderFontServedResponse {
    public let response: HTTPURLResponse
    public let data: Data
}

public enum SharedReaderFontInjectionMode: String, Equatable, Sendable {
    case localScheme
    case blob
}

internal enum SharedReaderFontScheme: String, Sendable {
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

internal enum SharedReaderFontRoute: Equatable, Sendable {
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

internal func sharedReaderFontStylesheetURL(for pageURL: URL, familyName: String) -> URL? {
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
    asset: SharedReaderFontAsset
) -> URL? {
    guard let baseURL = sharedReaderFontBaseURL(for: pageURL),
          let scheme = SharedReaderFontScheme(pageURL: baseURL) else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = scheme.host
    components.path = scheme.fontPathPrefix + asset.publicFilename
    return components.url
}

internal func sharedReaderFontRoute(
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

public func sharedReaderFontResponse(
    for requestURL: URL,
    asset: SharedReaderFontAsset?
) -> SharedReaderFontServedResponse? {
    guard let route = sharedReaderFontRoute(for: requestURL, asset: asset) else { return nil }
    let routeDescription: String
    let requestedFamilyName: String
    switch route {
    case .stylesheet(let familyName):
        routeDescription = "stylesheet"
        requestedFamilyName = familyName
    case .font:
        routeDescription = "font"
        requestedFamilyName = ""
    }

    let baseMetadata: [String: String] = [
        "requestURL": requestURL.absoluteString,
        "scheme": requestURL.scheme ?? "nil",
        "route": routeDescription,
        "family": requestedFamilyName.isEmpty ? "nil" : requestedFamilyName,
        "assetPresent": asset == nil ? "0" : "1",
        "assetFilename": asset?.publicFilename ?? "nil",
        "assetFormat": asset?.format ?? "nil",
        "assetMimeType": asset?.mimeType ?? "nil",
        "supportedFamilies": asset?.supportedFamilyNames.joined(separator: "|") ?? "nil",
    ]
    guard let asset else {
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 404,
            contentType: "text/plain",
            textEncodingName: "utf-8"
        )
        sharedReaderFontLog(
            "response",
            baseMetadata.merging(
                [
                    "status": "404",
                    "reason": "missingAsset",
                    "byteCount": "0",
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        return SharedReaderFontServedResponse(response: response, data: Data())
    }

    switch route {
    case .stylesheet(let familyName):
        let supportsFamily = asset.supportsFamily(familyName)
        let fontURL = sharedReaderFontFontURL(for: requestURL, asset: asset)
        guard supportsFamily,
              let fontURL else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8"
            )
            sharedReaderFontLog(
                "response",
                baseMetadata.merging(
                    [
                        "status": "404",
                        "reason": supportsFamily ? "missingFontURL" : "unsupportedFamily",
                        "supportsFamily": supportsFamily ? "1" : "0",
                        "fontURL": fontURL?.absoluteString ?? "nil",
                        "byteCount": "0",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }

        let css = """
        @font-face {
          font-family: '\(familyName)';
          font-weight: 500;
          font-style: normal;
          src: url("\(fontURL.absoluteString)") format("\(asset.format)");
          font-display: swap;
        }
        :root {
          --mnb-content-font: '\(familyName)';
          --mnb-content-vertical-font: '\(familyName)';
        }
        html,
        body,
        body *:not(.mnb-tracking-container):not(.mnb-tracking-container *):not(#page-tracking-container):not(#page-tracking-container *):not(#nav-hidden-buttons):not(#nav-hidden-buttons *):not(#nav-bar):not(#nav-bar *):not(rt) {
          font-family: '\(familyName)' !important;
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
        sharedReaderFontLog(
            "response",
            baseMetadata.merging(
                [
                    "status": "200",
                    "reason": "ok",
                    "supportsFamily": "1",
                    "fontURL": fontURL.absoluteString,
                    "byteCount": String(data.count),
                    "containsAtFontFace": css.contains("@font-face") ? "1" : "0",
                    "containsFontFamilyApplyRule": css.contains("font-family: '\\(familyName)' !important") ? "1" : "0",
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        return SharedReaderFontServedResponse(response: response, data: data)

    case .font:
        guard let data = try? Data(contentsOf: asset.localFileURL) else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8"
            )
            sharedReaderFontLog(
                "response",
                baseMetadata.merging(
                    [
                        "status": "404",
                        "reason": "fontFileReadFailed",
                        "assetLocalPath": asset.localFileURL.path,
                        "byteCount": "0",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 200,
            contentType: asset.mimeType,
            extraHeaders: ["Access-Control-Allow-Origin": "*"]
        )
        sharedReaderFontLog(
            "response",
            baseMetadata.merging(
                [
                    "status": "200",
                    "reason": "ok",
                    "assetLocalPath": asset.localFileURL.path,
                    "byteCount": String(data.count),
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        return SharedReaderFontServedResponse(response: response, data: data)
    }
}
