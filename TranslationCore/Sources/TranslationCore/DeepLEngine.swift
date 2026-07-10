import Foundation

public final class DeepLEngine: TranslationEngine {
    private let secrets: SecretStore
    private let http: HTTPClient
    private let host: String

    public init(secrets: SecretStore, http: HTTPClient, host: String = "api-free.deepl.com") {
        self.secrets = secrets; self.http = http; self.host = host
    }

    /// Maps our target locale to DeepL's language code, distinguishing Traditional
    /// (`ZH-HANT`) from Simplified (`ZH-HANS`) Chinese.
    private func deepLTarget(_ code: String) -> String {
        switch code.lowercased() {
        case "zh-tw", "zh-hant": return "ZH-HANT"
        case "zh-cn", "zh-hans": return "ZH-HANS"
        default: return code.uppercased()
        }
    }

    /// Maps our source locale to DeepL's language code.
    private func deepLSource(_ code: String) -> String {
        code.lowercased().hasPrefix("zh") ? "ZH" : code.uppercased()
    }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard let key = secrets.get(deepLKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
        let url = URL(string: "https://\(host)/v2/translate")!
        let headers = ["Authorization": "DeepL-Auth-Key \(key)"]
        var form = ["text": text, "target_lang": deepLTarget(target)]
        // Omit `source_lang` so DeepL auto-detects when the caller passes "auto".
        if source != "auto" { form["source_lang"] = deepLSource(source) }

        let resp: HTTPResponse
        do { resp = try await http.post(url: url, headers: headers, form: form) }
        catch { throw TranslationError.network("\(error)") }

        switch resp.status {
        case 200: break
        case 456: throw TranslationError.quotaExceeded
        default: throw TranslationError.http(resp.status)
        }

        struct Payload: Decodable { struct T: Decodable { let text: String }; let translations: [T] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: resp.body),
              let text = payload.translations.first?.text, !text.isEmpty else {
            throw TranslationError.empty
        }
        return text
    }
}
