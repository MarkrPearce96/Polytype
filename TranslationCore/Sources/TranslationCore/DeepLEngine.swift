import Foundation

public final class DeepLEngine: TranslationEngine {
    private let secrets: SecretStore
    private let http: HTTPClient
    private let host: String

    public init(secrets: SecretStore, http: HTTPClient, host: String = "api-free.deepl.com") {
        self.secrets = secrets; self.http = http; self.host = host
    }

    /// Maps our target locale to DeepL's language code.
    private func deepLTarget(_ target: String) -> String {
        target.lowercased().hasPrefix("zh") ? "ZH-HANT" : target.uppercased()
    }

    public func translate(_ english: String, to target: String) async throws -> String {
        guard let key = secrets.get(deepLKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
        let url = URL(string: "https://\(host)/v2/translate")!
        let headers = ["Authorization": "DeepL-Auth-Key \(key)"]
        let form = ["text": english, "source_lang": "EN", "target_lang": deepLTarget(target)]

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
