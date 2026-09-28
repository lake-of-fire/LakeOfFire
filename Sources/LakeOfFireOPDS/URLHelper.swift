//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

enum URLHelper {
    // Preserve URI delimiters and existing percent escapes. This fallback also
    // supports IRIs on older Foundation versions whose URL initializer is strict.
    private static let referenceCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    static func resolve(href: String?, base: URL?) -> URL? {
        guard let href else { return nil }
        if href.isEmpty {
            guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: true),
                  components.scheme != nil else { return nil }
            components.fragment = nil
            return components.url
        }
        let encoded = href.addingPercentEncoding(withAllowedCharacters: referenceCharacters)
        guard let url = (URL(string: href, relativeTo: base)
            ?? encoded.flatMap { URL(string: $0, relativeTo: base) })?.absoluteURL,
              url.scheme != nil else { return nil }
        return url
    }

    static func isAbsolute(href: String) -> Bool {
        resolve(href: href, base: nil) != nil
    }

    static func getAbsolute(href: String?, base: URL?) -> String? {
        resolve(href: href, base: base)?.absoluteString
    }
}
