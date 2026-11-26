import Foundation
import Testing

/// The UI is written in English; Spanish lives in Resources/Localizable.xcstrings
/// (`make strings` adds new keys). Every key needs a Spanish value with the
/// same placeholders, or the app shows English, or crashes on a bad format.
@Test func everyStringHasASpanishTranslation() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Localizable.xcstrings")
    let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(catalog["sourceLanguage"] as? String == "en")
    let strings = try #require(catalog["strings"] as? [String: [String: Any]])
    #expect(strings.count > 250)
    let placeholder = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@|lf|f|g)")
    func placeholders(_ text: String) -> [String] {
        placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
    }
    for (key, entry) in strings where !key.isEmpty {
        let unit = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
        let value = unit?["value"] as? String ?? ""
        #expect(unit?["state"] as? String == "translated" && !value.isEmpty, "no Spanish for \"\(key)\"")
        #expect(placeholders(value) == placeholders(key), "placeholders differ for \"\(key)\": \"\(value)\"")
        #expect(entry["extractionState"] as? String != "stale", "\"\(key)\" is no longer used; run make strings")
    }
}
