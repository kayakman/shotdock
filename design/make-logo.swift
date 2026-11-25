#!/usr/bin/env swift
// Derives transparent versions of design/logo.png: the original colours for
// light backgrounds and a white wordmark for dark ones. Writes them to
// design/ (for the README) and to the Logo image set (About window).
//
//   swift design/make-logo.swift

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("design")
let source = NSBitmapImageRep(data: try Data(contentsOf: design.appendingPathComponent("logo.png")))!
let w = source.pixelsWide, h = source.pixelsHigh

// The logo is drawn over white in two inks: graphite and orange.
let graphite = (r: 22.0, g: 23.0, b: 26.0)
let orange = (r: 255.0, g: 90.0, b: 31.0)

func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
    var p = [Int](repeating: 0, count: 4)
    source.getPixel(&p, atX: x, y: y)
    return (Double(p[0]), Double(p[1]), Double(p[2]))
}

// Content bounds: anything visibly darker than the white page.
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let c = rgb(x, y)
    if min(c.r, c.g, c.b) < 235 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}}
let margin = 24
let crop = (x: max(0, minX - margin), y: max(0, minY - margin),
            w: min(w, maxX + margin + 1) - max(0, minX - margin), h: min(h, maxY + margin + 1) - max(0, minY - margin))

/// Recovers ink and coverage from a pixel composited over white.
func unmix(_ c: (r: Double, g: Double, b: Double), darkInk: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double, a: Double) {
    if c.r - c.b > 40 {
        let a = min(1, max(0, (250 - c.b) / (250 - orange.b)))
        return (orange.r, orange.g, orange.b, a)
    }
    // White point slightly below 255 so the page's off-white noise stays fully transparent.
    let paper = 250.0
    let a = min(1, max(0, (paper - (c.r + c.g + c.b) / 3) / (paper - (graphite.r + graphite.g + graphite.b) / 3)))
    return (darkInk.r, darkInk.g, darkInk.b, a)
}

func makeLogo(darkInk: (r: Double, g: Double, b: Double)) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.w, pixelsHigh: crop.h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bitmapFormat: [.alphaNonpremultiplied], bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<crop.h { for x in 0..<crop.w {
        let u = unmix(rgb(crop.x + x, crop.y + y), darkInk: darkInk)
        var p = [Int(u.r), Int(u.g), Int(u.b), Int((u.a * 255).rounded())]
        rep.setPixel(&p, atX: x, y: y)
    }}
    rep.size = NSSize(width: crop.w / 2, height: crop.h / 2)  // @2x
    return rep
}

func scaled(_ rep: NSBitmapImageRep, by factor: Double) -> NSBitmapImageRep {
    let pw = Int(Double(rep.pixelsWide) * factor), ph = Int(Double(rep.pixelsHigh) * factor)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

func write(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let light = makeLogo(darkInk: graphite)
let dark = makeLogo(darkInk: (255, 255, 255))
try write(light, design.appendingPathComponent("logo-transparente.png"))
try write(dark, design.appendingPathComponent("logo-blanco.png"))

let set = root.appendingPathComponent("Resources/Assets.xcassets/Logo.imageset")
try write(light, set.appendingPathComponent("Logo@2x.png"))
try write(scaled(light, by: 0.5), set.appendingPathComponent("Logo.png"))
try write(dark, set.appendingPathComponent("LogoDark@2x.png"))
try write(scaled(dark, by: 0.5), set.appendingPathComponent("LogoDark.png"))
let darkAppearance = [["appearance": "luminosity", "value": "dark"]]
let contents: [String: Any] = [
    "images": [
        ["filename": "Logo.png", "idiom": "universal", "scale": "1x"],
        ["filename": "Logo@2x.png", "idiom": "universal", "scale": "2x"],
        ["filename": "LogoDark.png", "idiom": "universal", "scale": "1x", "appearances": darkAppearance],
        ["filename": "LogoDark@2x.png", "idiom": "universal", "scale": "2x", "appearances": darkAppearance],
    ],
    "info": ["author": "xcode", "version": 1],
]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
print("Logo \(crop.w)x\(crop.h) px written")
