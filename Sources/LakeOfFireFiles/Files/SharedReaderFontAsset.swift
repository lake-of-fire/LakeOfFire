import Foundation

private func sharedReaderFontLog(_ stage: String, _ details: [String: String]) {
    var segments: [String] = ["# READERLOAD stage=\(stage)"]
    for key in details.keys.sorted() {
        if let value = details[key] {
            segments.append("\(key)=\(value)")
        }
    }
    debugPrint(segments.joined(separator: " "))
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

public enum SharedReaderFontScheme: String, Sendable {
    case ebook
    case internalLocal = "internal"
    case readerFile = "reader-file"

    public init?(pageURL: URL) {
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

    public var host: String {
        switch self {
        case .ebook:
            return "ebook"
        case .internalLocal:
            return "local"
        case .readerFile:
            return "file"
        }
    }

    public var stylesheetPath: String {
        switch self {
        case .ebook:
            return "/load/manabi-fonts.css"
        case .internalLocal, .readerFile:
            return "/manabi-fonts.css"
        }
    }

    public var fontPathPrefix: String {
        switch self {
        case .ebook:
            return "/load/manabi-fonts/"
        case .internalLocal, .readerFile:
            return "/manabi-fonts/"
        }
    }
}

public enum SharedReaderFontRoute: Equatable, Sendable {
    case stylesheet(familyName: String)
    case font
}

public func sharedReaderFontUsesLocalScheme(for pageURL: URL) -> Bool {
    SharedReaderFontScheme(pageURL: pageURL) != nil
}

public func sharedReaderFontInjectionMode(for pageURL: URL) -> SharedReaderFontInjectionMode {
    sharedReaderFontUsesLocalScheme(for: pageURL) ? .localScheme : .blob
}

public func sharedReaderFontStylesheetURL(for pageURL: URL, familyName: String) -> URL? {
    guard let scheme = SharedReaderFontScheme(pageURL: pageURL) else { return nil }
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
    guard let scheme = SharedReaderFontScheme(pageURL: pageURL) else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = scheme.host
    components.path = scheme.fontPathPrefix + asset.publicFilename
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

public func sharedReaderFontResponse(
    for requestURL: URL,
    asset: SharedReaderFontAsset?
) -> SharedReaderFontServedResponse? {
    let startedAt = Date()
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
        sharedReaderFontLog(
            "sharedReaderFont.stylesheetRequest",
            [
                "family": familyName,
                "mode": sharedReaderFontInjectionMode(for: requestURL).rawValue,
                "url": requestURL.absoluteString
            ]
        )
        guard asset.supportsFamily(familyName),
              let fontURL = sharedReaderFontFontURL(for: requestURL, asset: asset) else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8"
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }

        let css = """
        @font-face {
          font-family: '\(familyName)';
          font-weight: 500;
          font-style: normal;
          src: url("\(fontURL.absoluteString)") format("\(asset.format)");
          font-display: block;
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
        let readStartedAt = Date()
        guard let data = try? Data(contentsOf: asset.localFileURL) else {
            let response = sharedReaderFontHTTPResponse(
                url: requestURL,
                statusCode: 404,
                contentType: "text/plain",
                textEncodingName: "utf-8"
            )
            return SharedReaderFontServedResponse(response: response, data: Data())
        }
        sharedReaderFontLog(
            "sharedReaderFont.fontRead",
            [
                "bytes": String(data.count),
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(readStartedAt)),
                "file": asset.localFileURL.lastPathComponent,
                "mode": sharedReaderFontInjectionMode(for: requestURL).rawValue,
                "totalElapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": requestURL.absoluteString
            ]
        )
        let response = sharedReaderFontHTTPResponse(
            url: requestURL,
            statusCode: 200,
            contentType: asset.mimeType,
            extraHeaders: ["Access-Control-Allow-Origin": "*"]
        )
        return SharedReaderFontServedResponse(response: response, data: data)
    }
}
