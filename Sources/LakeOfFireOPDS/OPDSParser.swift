//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OPDSParserError: LocalizedError {
    case documentNotFound
    case documentNotValid
    case httpStatus(Int)
    case partialDocument

    var errorDescription: String? {
        switch self {
        case .documentNotFound: return "The catalog document could not be loaded."
        case .documentNotValid: return "The response is not a valid OPDS document."
        case .httpStatus(let status): return "The catalog server returned HTTP \(status)."
        case .partialDocument: return "The catalog server returned an incomplete document."
        }
    }
}

public enum OPDSParser {
    /// Parse an OPDS feed or publication.
    /// Feed can be v1 (XML) or v2 (JSON).
    /// - parameter url: The feed URL
    /// - parameter completion: Runs on the URLSession callback executor. Captures
    ///   must be Sendable; the freshly parsed mutable result is transferred to
    ///   this callback and is not retained by the parser. Hop to a UI actor before
    ///   touching UI state. The result models themselves are not thread-safe.
    public static func parseURL(url: URL, completion: @escaping @Sendable (sending ParseData?, Error?) -> Void) {
        parseURL(url: url, session: .shared, completion: completion)
    }

    // Keep transport selection explicit for isolated hosts/tests without changing
    // the existing public entry point or mutating URLSession.shared globally.
    static func parseURL(url: URL, session: URLSession, completion: @escaping @Sendable (sending ParseData?, Error?) -> Void) {
        loadDocument(url: url, session: session) { data, response, error in
            guard let data = data, let response = response else {
                completion(nil, error ?? OPDSParserError.documentNotFound)
                return
            }

            do {
                completion(try parseDocument(data: data, url: url, response: response), nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    /// Loads a catalog in the calling task's lifetime. Cancellation reaches the
    /// URLSession task; a cancelled caller cannot receive a successful result.
    /// The fresh mutable graph is transferred to the caller, not shared.
    public static func parseURL(
        url: URL,
        session: URLSession = .shared
    ) async throws -> sending ParseData {
        try Task.checkCancellation()
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        let (validatedData, validatedResponse) = try validateDocument(
            data: data, response: response, error: nil
        )
        let result = try parseDocument(data: validatedData, url: url, response: validatedResponse)
        try Task.checkCancellation()
        return result
    }

    private static func parseDocument(data: Data, url: URL, response: URLResponse) throws -> ParseData {
        // Retain the existing XML-first, JSON-second format selection for both
        // entry points. HTTP/transport admission precedes either parser.
        if let result = try? OPDS1Parser.parse(xmlData: data, url: url, response: response) {
            return result
        }
        if let result = try? OPDS2Parser.parse(jsonData: data, url: url, response: response) {
            return result
        }
        throw OPDSParserError.documentNotValid
    }

    static func loadDocument(url: URL, session: URLSession = .shared, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        session.dataTask(with: url) { data, response, error in
            do {
                let (data, response) = try validateDocument(data: data, response: response, error: error)
                completion(data, response, nil)
            } catch {
                completion(nil, response, error)
            }
        }.resume()
    }

    static func validateDocument(data: Data?, response: URLResponse?, error: Error?) throws -> (Data, URLResponse) {
        if let error { throw error }
        if let response = response as? HTTPURLResponse {
            guard (200..<300).contains(response.statusCode) else {
                throw OPDSParserError.httpStatus(response.statusCode)
            }
            // No catalog request sends a Range header. A syntactically complete
            // fragment must not be admitted as the complete catalog.
            guard response.statusCode != 206 else { throw OPDSParserError.partialDocument }
        }
        guard let data, let response else { throw OPDSParserError.documentNotFound }
        return (data, response)
    }
}
