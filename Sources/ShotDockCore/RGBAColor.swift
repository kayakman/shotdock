import CoreGraphics

public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let red = RGBAColor(red: 0.96, green: 0.23, blue: 0.21)
    public static let orange = RGBAColor(red: 1.0, green: 0.58, blue: 0.0)
    public static let yellow = RGBAColor(red: 1.0, green: 0.84, blue: 0.04)
    public static let green = RGBAColor(red: 0.20, green: 0.78, blue: 0.35)
    public static let blue = RGBAColor(red: 0.04, green: 0.52, blue: 1.0)
    public static let purple = RGBAColor(red: 0.69, green: 0.32, blue: 0.87)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    public static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

public extension RGBAColor {
    /// Names accepted by `init(string:)`, from the editor's palette.
    static let names = ["red", "orange", "yellow", "green", "blue", "purple", "black", "white"]

    /// Reads `#RGB`, `#RRGGBB`, `#RRGGBBAA` (the `#` is optional) or a palette name.
    init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespaces).lowercased()
        if let index = Self.names.firstIndex(of: text) {
            self = Self.palette[index]
            return
        }
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let bytes = hex.count == 6 ? value << 8 | 0xFF : value
        self.init(red: Double(bytes >> 24 & 0xFF) / 255, green: Double(bytes >> 16 & 0xFF) / 255,
                  blue: Double(bytes >> 8 & 0xFF) / 255, alpha: Double(bytes & 0xFF) / 255)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha < 1 ? rgb + String(format: "%02X", byte(alpha)) : rgb
    }
}
