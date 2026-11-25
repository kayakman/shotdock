#!/usr/bin/env swift
// Generates every ShotDock icon from one vector description of design/icono.png:
// the SVG sources in design/, the AppIcon set, the menu bar template and the
// accent colour in Resources/Assets.xcassets.
//
//   swift design/make-icons.swift
//
// Geometry is in a 1024 × 1024 canvas, top-left origin, following the macOS
// icon template: an 824 × 824 squircle at (100, 100) with continuous corners.

import AppKit
import SwiftUI

// MARK: - Description

struct RGB { let r, g, b: CGFloat; var a: CGFloat = 1
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
    init(_ hex: UInt32) { r = CGFloat(hex >> 16 & 0xFF) / 255; g = CGFloat(hex >> 8 & 0xFF) / 255; b = CGFloat(hex & 0xFF) / 255 }
}

let orange = RGB(0xFF5A1F)
let white = RGB(0xFFFFFF)
// Vertical gradient sampled from design/icono.png (≈ #16171A in the middle).
let graphite: [(RGB, CGFloat)] = [(RGB(0x2D2E32), 0), (RGB(0x141518), 0.5), (RGB(0x050608), 1)]

enum Mark {
    /// A stroked polyline with round caps and joins. `fadeFrom` makes the
    /// stroke transparent at that x, fully opaque at `fadeTo` (speed lines).
    case stroke([CGPoint], width: CGFloat, color: RGB, fade: (from: CGFloat, to: CGFloat)? = nil, square: Bool = false)
    case dot(CGPoint, radius: CGFloat, color: RGB)
}

/// Maps a point measured on design/icono.png (squircle 105…916 × 108…910)
/// onto the template squircle.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let k = 824 / 806.5
    return CGPoint(x: 512 + (x - 510.5) * k, y: 512 + (y - 509) * k)
}
let k: CGFloat = 824 / 806.5

func brackets(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat,
              armX: CGFloat, armY: CGFloat, width: CGFloat, color: RGB, square: Bool = false,
              map: (CGFloat, CGFloat) -> CGPoint) -> [Mark] {
    [
        .stroke([map(left + armX, top), map(left, top), map(left, top + armY)], width: width, color: color, square: square),
        .stroke([map(right - armX, top), map(right, top), map(right, top + armY)], width: width, color: color, square: square),
        .stroke([map(left, bottom - armY), map(left, bottom), map(left + armX, bottom)], width: width, color: color, square: square),
        .stroke([map(right, bottom - armY), map(right, bottom), map(right - armX, bottom)], width: width, color: color, square: square),
    ]
}

/// The full icon, as drawn in design/icono.png.
let fullMarks: [Mark] = {
    var marks: [Mark] = [
        .stroke([p(150, 425), p(315, 425)], width: 20 * k, color: orange, fade: (p(150, 0).x, p(250, 0).x)),
        .stroke([p(140, 495), p(360, 495)], width: 20 * k, color: orange, fade: (p(140, 0).x, p(250, 0).x)),
        .stroke([p(160, 557), p(315, 557)], width: 20 * k, color: orange, fade: (p(160, 0).x, p(255, 0).x)),
    ]
    marks += brackets(left: 372, right: 747, top: 316, bottom: 666, armX: 104, armY: 96,
                      width: 18 * k, color: white, map: p)
    let c = (x: CGFloat(559.5), y: CGFloat(495))
    marks += [
        .stroke([p(c.x, 419), p(c.x, 451)], width: 15.5 * k, color: orange),
        .stroke([p(c.x, 539), p(c.x, 571)], width: 15.5 * k, color: orange),
        .stroke([p(475, c.y), p(515, c.y)], width: 15.5 * k, color: orange),
        .stroke([p(603, c.y), p(643, c.y)], width: 15.5 * k, color: orange),
        .dot(p(c.x, c.y), radius: 24.5 * k, color: orange),
    ]
    return marks
}()

/// 16 and 32 px: no speed lines or crosshair arms, centred, heavier strokes
/// with square caps snapped to the pixel grid so they stay crisp.
func smallMarks(pixels: Int) -> [Mark] {
    let u = 1024 / CGFloat(pixels)  // canvas units per pixel
    let px = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * u, y: y * u) }
    if pixels <= 16 {
        // 1 px strokes centred on pixel centres; 2 × 2 px dot.
        return brackets(left: 4.5, right: 11.5, top: 4.5, bottom: 11.5, armX: 2, armY: 2,
                        width: u, color: white, square: true, map: px)
            + [.dot(px(8, 8), radius: u, color: orange)]
    }
    // 32 px: 2 px strokes on pixel edges; 6 px dot.
    return brackets(left: 9, right: 23, top: 9, bottom: 23, armX: 4, armY: 4,
                    width: 2 * u, color: white, square: true, map: px)
        + [.dot(px(16, 16), radius: 3 * u, color: orange)]
}

let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle: CGPath = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: squircleRect).cgPath

/// Menu bar template, in an 18 × 18 pt canvas: corners and the dot, black.
let menuBarSize: CGFloat = 18
let menuBarMarks: [Mark] = {
    let id = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
    let black = RGB(0x000000)
    return brackets(left: 2, right: 16, top: 2.5, bottom: 15.5, armX: 4.6, armY: 4.2,
                    width: 1.7, color: black, map: id)
        + [.dot(CGPoint(x: 9, y: 9), radius: 2.4, color: black)]
}()

// MARK: - Rendering

func path(for points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    return path
}

func draw(_ marks: [Mark], in ctx: CGContext) {
    for mark in marks {
        switch mark {
        case let .stroke(points, width, color, fade, square):
            ctx.saveGState()
            ctx.setLineWidth(width)
            ctx.setLineCap(square ? .square : .round)
            ctx.setLineJoin(square ? .miter : .round)
            if let fade {
                ctx.addPath(path(for: points))
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [color.cg.copy(alpha: 0)!, color.cg] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(gradient, start: CGPoint(x: fade.from, y: 0), end: CGPoint(x: fade.to, y: 0),
                                       options: [.drawsAfterEndLocation])
            } else {
                ctx.setStrokeColor(color.cg)
                ctx.addPath(path(for: points))
                ctx.strokePath()
            }
            ctx.restoreGState()
        case let .dot(center, radius, color):
            ctx.setFillColor(color.cg)
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

func drawIcon(_ marks: [Mark], in ctx: CGContext, pixels: Int) {
    ctx.saveGState()
    if pixels >= 64 {
        // Template drop shadow. Shadow geometry ignores the CTM: it is in
        // device pixels, with y pointing up.
        let s = CGFloat(pixels) / 1024
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: CGColor(gray: 0, alpha: 0.3))
    }
    ctx.addPath(squircle)
    ctx.setFillColor(graphite[1].0.cg)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: graphite.map(\.0.cg) as CFArray, locations: graphite.map(\.1))!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: squircleRect.minY), end: CGPoint(x: 0, y: squircleRect.maxY), options: [])
    ctx.restoreGState()
    draw(marks, in: ctx)
}

func png(size: Int, marks: [Mark], to url: URL) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    drawIcon(marks, in: ctx, pixels: size)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func menuBarPDF(to url: URL) {
    var box = CGRect(x: 0, y: 0, width: menuBarSize, height: menuBarSize)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: menuBarSize)
    ctx.scaleBy(x: 1, y: -1)
    draw(menuBarMarks, in: ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

// MARK: - SVG

func svgPath(_ path: CGPath) -> String {
    var d = ""
    let f = { (v: CGFloat) in String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let e = element.pointee, pts = e.points
        switch e.type {
        case .moveToPoint: d += "M\(f(pts[0].x)) \(f(pts[0].y))"
        case .addLineToPoint: d += "L\(f(pts[0].x)) \(f(pts[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y))"
        case .addCurveToPoint: d += "C\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y)) \(f(pts[2].x)) \(f(pts[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(_ marks: [Mark], size: CGFloat, background: Bool) -> String {
    let f = { (v: CGFloat) in String(format: "%.2f", v) }
    var defs = "", body = ""
    if background {
        defs += """
          <linearGradient id="graphite" x1="0" y1="\(f(squircleRect.minY))" x2="0" y2="\(f(squircleRect.maxY))" gradientUnits="userSpaceOnUse">
            \(graphite.map { "<stop offset=\"\($0.1)\" stop-color=\"\($0.0.hex)\"/>" }.joined())
          </linearGradient>
          <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
            <feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/>
          </filter>

        """
        body += "  <path d=\"\(svgPath(squircle))\" fill=\"url(#graphite)\" filter=\"url(#shadow)\"/>\n"
    }
    for (index, mark) in marks.enumerated() {
        switch mark {
        case let .stroke(points, width, color, fade, square):
            let pts = points.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            var paint = color.hex
            if let fade {
                defs += """
                  <linearGradient id="fade\(index)" x1="\(f(fade.from))" y1="0" x2="\(f(fade.to))" y2="0" gradientUnits="userSpaceOnUse">
                    <stop offset="0" stop-color="\(color.hex)" stop-opacity="0"/><stop offset="1" stop-color="\(color.hex)"/>
                  </linearGradient>

                """
                paint = "url(#fade\(index))"
            }
            body += "  <polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(paint)\" stroke-width=\"\(f(width))\" stroke-linecap=\"\(square ? "square" : "round")\" stroke-linejoin=\"\(square ? "miter" : "round")\"/>\n"
        case let .dot(center, radius, color):
            body += "  <circle cx=\"\(f(center.x))\" cy=\"\(f(center.y))\" r=\"\(f(radius))\" fill=\"\(color.hex)\"/>\n"
        }
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(f(size))" height="\(f(size))" viewBox="0 0 \(f(size)) \(f(size))">
      <defs>
    \(defs)  </defs>
    \(body)</svg>

    """
}

// MARK: - Output

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("design")
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let fm = FileManager.default

func writeJSON(_ object: Any, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

try svg(fullMarks, size: 1024, background: true).write(to: design.appendingPathComponent("icono.svg"), atomically: true, encoding: .utf8)
try svg(smallMarks(pixels: 32), size: 1024, background: true).write(to: design.appendingPathComponent("icono-pequeno.svg"), atomically: true, encoding: .utf8)
try svg(menuBarMarks, size: menuBarSize, background: false).write(to: design.appendingPathComponent("barra-de-menus.svg"), atomically: true, encoding: .utf8)

try writeJSON(["info": ["author": "xcode", "version": 1]], to: assets.appendingPathComponent("Contents.json"))

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconSet)
try fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: pixels, marks: pixels <= 32 ? smallMarks(pixels: pixels) : fullMarks, to: iconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
try writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: iconSet.appendingPathComponent("Contents.json"))

let menuBarSet = assets.appendingPathComponent("MenuBarIcon.imageset")
try fm.createDirectory(at: menuBarSet, withIntermediateDirectories: true)
menuBarPDF(to: menuBarSet.appendingPathComponent("MenuBarIcon.pdf"))
try writeJSON([
    "images": [["filename": "MenuBarIcon.pdf", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
], to: menuBarSet.appendingPathComponent("Contents.json"))

try writeJSON([
    "colors": [["idiom": "universal", "color": ["color-space": "srgb", "components": [
        "red": "0xFF", "green": "0x5A", "blue": "0x1F", "alpha": "1.000"]]]],
    "info": ["author": "xcode", "version": 1],
], to: assets.appendingPathComponent("AccentColor.colorset/Contents.json"))

print("Icons written to \(design.path) and \(assets.path)")
