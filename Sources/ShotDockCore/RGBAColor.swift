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
