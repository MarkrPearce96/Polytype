import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient: Sendable {
    func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse
}

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = form.map { key, value in
            let e = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
            return "\(e(key))=\(e(value))"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(status: status, body: data)
    }
}
