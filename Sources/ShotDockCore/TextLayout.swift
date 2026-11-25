import CoreGraphics
import CoreText
import Foundation

/// Measures and draws the multi-line text of a text annotation, so the editor
/// and the exported image lay it out identically.
public struct TextLayout {
    public let lines: [CTLine]
    public let ascent: CGFloat
    public let lineHeight: CGFloat
    public let size: CGSize

    public init(string: String, fontSize: CGFloat, color: CGColor? = nil) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let parts = string.isEmpty ? [""] : string.components(separatedBy: "\n")
        lines = parts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        ascent = CTFontGetAscent(font)
        lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        size = CGSize(width: ceil(max(width, fontSize * 0.3)), height: lineHeight * CGFloat(lines.count))
    }

    /// Draws with `origin` as the top-left corner in a top-left-origin context.
    public func draw(at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent + CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}
