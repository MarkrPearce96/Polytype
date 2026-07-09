import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient: Sendable {
    func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse
}

/// RFC 3986 application/x-www-form-urlencoded encoding.
enum FormURLEncoding {
    /// Unreserved ASCII characters that are NOT percent-encoded.
    static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ form: [String: String]) -> String {
        form.map { key, value in
            let e = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
            return "\(e(key))=\(e(value))"
        }.joined(separator: "&")
    }
}

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = FormURLEncoding.encode(form).data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(status: status, body: data)
    }
}
