import Foundation

/// Google Cloud Translation — Basic (v2). Free tier: 500,000 characters/month.
///
/// Uses the simple API-key REST endpoint (no OAuth/service account): the key is
/// created in the Google Cloud console with the Cloud Translation API enabled.
public final class GoogleEngine: TranslationEngine {
    private let secrets: SecretStore
    private let http: HTTPClient
    private let host: String

    public init(secrets: SecretStore, http: HTTPClient,
                host: String = "translation.googleapis.com") {
        self.secrets = secrets; self.http = http; self.host = host
    }

    /// Google's language codes: any Chinese variant → Traditional (Taiwan); others pass through.
    private func googleLang(_ code: String) -> String {
        code.lowercased().hasPrefix("zh") ? "zh-TW" : code
    }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard let key = secrets.get(googleKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
        let url = URL(string: "https://\(host)/language/translate/v2")!
        let form = [
            "q": text,
            "source": googleLang(source),
            "target": googleLang(target),
            "format": "text",
            "key": key,
        ]

        let resp: HTTPResponse
        do { resp = try await http.post(url: url, headers: [:], form: form) }
        catch { throw TranslationError.network("\(error)") }

        switch resp.status {
        case 200: break
        case 429: throw TranslationError.quotaExceeded
        default: throw TranslationError.http(resp.status)
        }

        struct Payload: Decodable {
            struct DataField: Decodable {
                struct Translation: Decodable { let translatedText: String }
                let translations: [Translation]
            }
            let data: DataField
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: resp.body),
              let translated = payload.data.translations.first?.translatedText, !translated.isEmpty else {
            throw TranslationError.empty
        }
        return Self.unescapeHTML(translated)
    }

    /// The v2 API HTML-escapes its output even in `format=text` mode (a
    /// long-standing Google quirk), so `'` comes back as `&#39;`, `&` as `&amp;`,
    /// etc. Undo the common named and numeric entities so the pasted text is clean.
    static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                     "&quot;": "\"", "&#34;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return decodeNumericEntities(result)
    }

    /// Decode remaining `&#DDD;` / `&#xHH;` numeric character references.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let hashIdx = s.index(i, offsetBy: 1, limitedBy: s.endIndex), hashIdx < s.endIndex, s[hashIdx] == "#",
               let semi = s[i...].firstIndex(of: ";") {
                let start = s.index(i, offsetBy: 2)
                let numStr = s[start..<semi]
                let value: UInt32? = (numStr.first == "x" || numStr.first == "X")
                    ? UInt32(numStr.dropFirst(), radix: 16)
                    : UInt32(numStr, radix: 10)
                if let value, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
