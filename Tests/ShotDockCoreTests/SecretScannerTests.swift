import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

@Test func findsKeysTokensAndPasswords() {
    let text = "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE token: ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789 password = hunter2pass"
    let findings = SecretScanner.scan(text)
    #expect(findings.map(\.kind) == ["api_key", "token", "password"])
    #expect(findings[0].text == "AKIAIOSFODNN7EXAMPLE" && findings[0].masked == "AKIA…(20)")
    #expect(findings[2].text == "hunter2pass")
    #expect(SecretScanner.scan("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345").first?.kind == "api_key")
    #expect(SecretScanner.scan("Authorization: Bearer abcdefghijklmnop1234").first?.text == "abcdefghijklmnop1234")
}

@Test func findsEmailsCardsAndIBANsWithChecks() {
    #expect(SecretScanner.scan("Escríbeme a ricardo@example.com mañana").map(\.text) == ["ricardo@example.com"])
    #expect(SecretScanner.scan("Tarjeta 4111 1111 1111 1111").first?.kind == "card")
    #expect(SecretScanner.scan("Pedido 4111 1111 1111 1112").isEmpty)  // fails Luhn
    #expect(SecretScanner.scan("IBAN ES91 2100 0418 4502 0005 1332").first?.kind == "iban")
    #expect(SecretScanner.scan("ES91 2100 0418 4502 0005 1333").isEmpty)  // wrong check digits
    #expect(SecretScanner.scan("Hola, esto es una frase normal con 2026 y 15:30.").isEmpty)
}

@Test func kindsCanBeChosen() {
    let text = "ricardo@example.com AKIAIOSFODNN7EXAMPLE"
    #expect(SecretScanner.scan(text, kinds: ["email"]).map(\.kind) == ["email"])
    #expect(SecretScanner.mask("abc") == "…(3)")
}

@Test func redactBoxesAreOpaqueAndHideFromMagnifiers() throws {
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    var document = CaptureDocument(image: context.makeImage()!, scale: 1)
    document.annotations = [
        Annotation(shape: .redact(CGRect(x: 10, y: 10, width: 40, height: 20)), style: AnnotationStyle(color: .black)),
        Annotation(shape: .magnifier(source: CGRect(x: 10, y: 10, width: 40, height: 20), target: CGRect(x: 100, y: 40, width: 80, height: 40), round: false),
                   style: AnnotationStyle(lineWidth: 2)),
    ]
    let flat = try #require(document.flattened())
    let covered = pixel(flat, 20, 15), enlarged = pixel(flat, 140, 60)
    #expect(covered.r < 10 && covered.g < 10 && covered.b < 10)
    #expect(enlarged.r < 10, "the magnifier shows the box, not what is under it")
    #expect(document.annotations[0].isPixelEffect && document.annotations[0].box != nil)
}
