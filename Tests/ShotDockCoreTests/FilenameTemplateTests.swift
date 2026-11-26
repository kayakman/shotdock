import Foundation
import Testing
@testable import ShotDockCore

private let utc = TimeZone(identifier: "UTC")!
private let date = Date(timeIntervalSince1970: 1_764_064_720)  // 2025-11-25 09:58:40 UTC

@Test func defaultTemplate() {
    #expect(FilenameTemplate().name(for: date, timeZone: utc) == "ShotDock 2025-11-25 at 09.58.40")
}

@Test func customTokensAndSanitizing() {
    let template = FilenameTemplate("{año}/{mes}/{día} {h}:{min}:{s} #{n}")
    #expect(template.name(for: date, counter: 7, timeZone: utc) == "2025-11-25 09.58.40 #7")
}

@Test func englishAndSpanishTokensBothWork() {
    #expect(FilenameTemplate("{date} {time} {year}{month}{day}").name(for: date, timeZone: utc) == "2025-11-25 09.58.40 20251125")
    #expect(FilenameTemplate("{fecha}_{hora}").name(for: date, timeZone: utc) == "2025-11-25_09.58.40")
}

@Test func emptyTemplateFallsBack() {
    #expect(FilenameTemplate("  ").name(for: date, timeZone: utc) == "ShotDock 2025-11-25 at 09.58.40")
}

@Test func uniqueURLAddsSuffix() {
    let folder = URL(fileURLWithPath: "/tmp/x")
    let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a 2.png"]
    let url = FilenameTemplate("a").uniqueURL(in: folder, for: date, format: .png) { taken.contains($0.path) }
    #expect(url.path == "/tmp/x/a 3.png")
}
