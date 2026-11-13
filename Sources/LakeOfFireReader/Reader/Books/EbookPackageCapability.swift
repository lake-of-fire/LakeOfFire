import Foundation

func ebookCanonicalPackageURL(_ url: URL) -> URL? {
    guard url.baseURL == nil,
          url.scheme == "ebook",
          url.host == "ebook",
          url.user == nil,
          url.password == nil,
          url.port == nil,
          url.pathComponents.starts(with: ["/", "load"]) else { return nil }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    components.query = nil
    components.fragment = nil
    return components.url
}

private func ebookPackageURLOwnedByDocument(_ documentURL: URL) -> URL? {
    if let directRequest = ebookDirectSectionRequest(from: documentURL) {
        return ebookCanonicalPackageURL(directRequest.sourceURL)
    }
    return ebookCanonicalPackageURL(documentURL)
}

func ebookPackageCapabilitySourceURL(
    for request: URLRequest,
    route _: String,
    expectedSourceURL: URL? = nil,
    allowsMissingMainDocument: Bool = false
) -> URL? {
    guard let requestURL = request.url else { return nil }
    let sourceQueryItems = URLComponents(
        url: requestURL,
        resolvingAgainstBaseURL: false
    )?.queryItems?.filter({ $0.name == "sourceURL" }) ?? []
    guard sourceQueryItems.count <= 1 else { return nil }

    let headerSourceURL: URL?
    if let headerValue = request.value(forHTTPHeaderField: "X-Ebook-Source-URL") {
        guard let resolvedURL = URL(string: headerValue).flatMap(ebookCanonicalPackageURL) else {
            return nil
        }
        headerSourceURL = resolvedURL
    } else {
        headerSourceURL = nil
    }

    let querySourceURL: URL?
    if let queryItem = sourceQueryItems.first {
        guard let queryValue = queryItem.value,
              let resolvedURL = URL(string: queryValue).flatMap(ebookCanonicalPackageURL) else {
            return nil
        }
        querySourceURL = resolvedURL
    } else {
        querySourceURL = nil
    }

    let mainDocumentSourceURL: URL?
    if let mainDocumentURL = request.mainDocumentURL {
        guard let resolvedURL = ebookPackageURLOwnedByDocument(mainDocumentURL) else {
            return nil
        }
        mainDocumentSourceURL = resolvedURL
    } else {
        mainDocumentSourceURL = nil
    }

    let canonicalExpectedSourceURL: URL?
    if let expectedSourceURL {
        guard let resolvedURL = ebookCanonicalPackageURL(expectedSourceURL) else { return nil }
        canonicalExpectedSourceURL = resolvedURL
    } else {
        canonicalExpectedSourceURL = nil
    }

    if request.mainDocumentURL == nil && !allowsMissingMainDocument { return nil }
    let candidates = [
        canonicalExpectedSourceURL,
        headerSourceURL,
        querySourceURL,
        mainDocumentSourceURL,
    ].compactMap { $0 }
    guard let sourceURL = candidates.first,
          candidates.dropFirst().allSatisfy({ $0 == sourceURL }) else {
        return nil
    }
    return sourceURL
}

func ebookProcessTextContentURL(for request: URLRequest) -> URL? {
    guard let rawContentURL = request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"),
          let contentURL = URL(string: rawContentURL),
          let canonicalContentURL = ebookCanonicalPackageURL(contentURL),
          ebookPackageCapabilitySourceURL(
              for: request,
              route: "/process-text",
              expectedSourceURL: canonicalContentURL
          ) == canonicalContentURL else {
        return nil
    }
    return canonicalContentURL
}

