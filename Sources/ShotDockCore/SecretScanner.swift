import Foundation

/// Finds secrets in recognised text: API keys and tokens, private keys,
/// passwords in "key: value" form, e-mail addresses, card numbers, IBANs.
/// Used to cover them with opaque boxes before a capture is shared or shown
/// to a model.
public enum SecretScanner {
    public struct Finding: Equatable, Sendable {
        public var kind: String
        public var range: Range<String.Index>
        public var text: String

        /// Enough to recognise it, never the secret: "ghp_…(40)".
        public var masked: String { SecretScanner.mask(text) }
    }

    public static let kinds = ["api_key", "token", "private_key", "password", "email", "card", "iban"]

    private struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// Capture group holding the secret (0: the whole match).
        let group: Int
        let check: (@Sendable (String) -> Bool)?

        init(_ kind: String, _ pattern: String, group: Int = 0, options: NSRegularExpression.Options = [], check: (@Sendable (String) -> Bool)? = nil) {
            self.kind = kind
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.group = group
            self.check = check
        }
    }

    private static let rules: [Rule] = [
        Rule("api_key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),                               // AWS access key id
        Rule("api_key", #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#),                     // OpenAI, Anthropic
        Rule("api_key", #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#),               // Stripe
        Rule("api_key", #"\bAIza[0-9A-Za-z_\-]{35}"#),                                   // Google
        Rule("token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#),                   // GitHub
        Rule("token", #"\bgithub_pat_[A-Za-z0-9_]{22,}"#),
        Rule("token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),                                  // GitLab
        Rule("token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),                              // Slack
        Rule("token", #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#), // JWT
        Rule("token", #"\b(?:Bearer|Basic)\s+([A-Za-z0-9_\-\.=+/]{16,})"#, group: 1),
        Rule("private_key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        Rule("password", #"\b(?:password|passwd|pwd|contraseña|clave|secret|token|api[_\-]?key|access[_\-]?key)\b\s*[:=]\s*["']?([^\s"']{4,})"#,
             group: 1, options: [.caseInsensitive]),
        Rule("email", #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        Rule("card", #"\b(?:\d[ \-]?){12,18}\d\b"#, check: { luhn($0) }),
        Rule("iban", #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#, check: { iban($0) }),
    ]

    /// The secrets in `text`, without overlaps, in order.
    public static func scan(_ text: String, kinds wanted: Set<String>? = nil) -> [Finding] {
        var findings: [Finding] = []
        let whole = NSRange(text.startIndex..., in: text)
        for rule in rules where wanted?.contains(rule.kind) ?? true {
            for match in rule.regex.matches(in: text, range: whole) {
                let nsRange = match.range(at: rule.group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { continue }
                let value = String(text[range])
                if let check = rule.check, !check(value) { continue }
                if findings.contains(where: { $0.range.overlaps(range) }) { continue }
                findings.append(Finding(kind: rule.kind, range: range, text: value))
            }
        }
        return findings.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public static func mask(_ secret: String) -> String {
        let visible = secret.count > 12 ? 4 : secret.count > 6 ? 2 : 0
        return String(secret.prefix(visible)) + "…(\(secret.count))"
    }

    static func luhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            let value = index % 2 == 1 ? digit * 2 : digit
            sum += value > 9 ? value - 9 : value
        }
        return sum % 10 == 0
    }

    static func iban(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let value: Int
            if let digit = character.wholeNumberValue { value = digit } else if let ascii = character.asciiValue, character.isLetter {
                value = Int(ascii) - 55
            } else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }
}

/// Covers the secrets of a capture with opaque boxes: the editor's
/// Imagen › Ocultar secretos, `shotdock redact` and `capture --redact`.
public enum Redaction {
    /// Redaction boxes for the secrets OCR finds in the edited image, in the
    /// document's coordinates, and what they cover (masked).
    public static func annotations(for document: CaptureDocument, kinds: Set<String> = []) async throws -> ([Annotation], [RecognizedSecret]) {
        guard let image = document.flattened() else { return ([], []) }
        let result = try await TextRecognition.recognize(image, secrets: kinds)
        let view = DocumentView(document)
        let pad = 2 * document.exportScale
        let style = AnnotationStyle(color: .black)
        let boxes = result.secrets.map { secret in
            Annotation(shape: .redact(view.toDocument(secret.box.insetBy(dx: -pad, dy: -pad)).integral), style: style)
        }
        return (boxes, result.secrets)
    }
}
