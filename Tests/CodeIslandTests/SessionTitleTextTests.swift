import XCTest
import CoreText
import AppKit
@testable import CodeIsland

final class SessionTitleTextTests: XCTestCase {

    // MARK: - Leading-glyph detection

    func testPlainTextHasNoLeadingGlyph() {
        XCTAssertFalse(sessionTitleHasLeadingGlyph(""))
        XCTAssertFalse(sessionTitleHasLeadingGlyph("my-feature"))
        XCTAssertFalse(sessionTitleHasLeadingGlyph("#my-title"))   // bare '#' is plain
        XCTAssertFalse(sessionTitleHasLeadingGlyph("1st attempt")) // digit plain
    }

    func testBMPPUADetected() {
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{E702} git"))    // U+E702 git glyph
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{F0279} list"))  // U+F0279 list glyph
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{F8FF}end"))     // BMP PUA upper bound
    }

    func testSupplementaryPUADetected() {
        if let a = Unicode.Scalar(0xF0000), let b = Unicode.Scalar(0x100000) {
            XCTAssertTrue(sessionTitleHasLeadingGlyph("\(String(a))sup"))
            XCTAssertTrue(sessionTitleHasLeadingGlyph("\(String(b))b"))
        }
    }

    func testEmojiDetected() {
        XCTAssertTrue(sessionTitleHasLeadingGlyph("🚀 launch"))
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{2764}\u{FE0F} task"))          // ❤️ VS-16
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{1F468}\u{200D}\u{1F4BB} dev")) // 👨‍💻 ZWJ
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{0023}\u{FE0F}\u{20E3} num"))   // #️⃣ keycap
        XCTAssertTrue(sessionTitleHasLeadingGlyph("\u{00A9}\u{FE0F} copy"))          // ©️ VS-16
    }

    // MARK: - Hash prefix

    func testHashPrefixPlain() {
        let plain = "my-feature"
        XCTAssertEqual(chars(sessionTitleAttributedString(plain, monoSize: 13, color: .white, hashPrefix: true)),  "#my-feature")
        XCTAssertEqual(chars(sessionTitleAttributedString(plain, monoSize: 13, color: .white, hashPrefix: false)), "my-feature")
    }

    func testHashPrefixSuppressedForPUA() {
        let title = "\u{E702} git"
        XCTAssertEqual(chars(sessionTitleAttributedString(title, monoSize: 13, color: .white, hashPrefix: true)), title)
    }

    func testHashPrefixSuppressedForEmoji() {
        XCTAssertEqual(chars(sessionTitleAttributedString("🚀 go",   monoSize: 13, color: .white, hashPrefix: true)), "🚀 go")
        let keycap = "\u{0023}\u{FE0F}\u{20E3} tag"
        XCTAssertEqual(chars(sessionTitleAttributedString(keycap,    monoSize: 13, color: .white, hashPrefix: true)), keycap)
        let zwj = "\u{1F468}\u{200D}\u{1F4BB} code"
        XCTAssertEqual(chars(sessionTitleAttributedString(zwj,       monoSize: 13, color: .white, hashPrefix: true)), zwj)
    }

    // MARK: - Font coverage via CTLine (production path)

    // Typesets the production AttributedString via CTLine and extracts the
    // CTFont CoreText actually chose for each code point — not a separate
    // loader. Proves E702 and F0279 are covered by SymbolsNF, not LastResort.

    func testE702FontCoverageViaProductionPath() throws {
        let size: CGFloat = 14
        let attr = sessionTitleAttributedString("\u{E702}", monoSize: size, color: .white)
        let ct   = try runFont(attr, utf16Position: 0)
        let ps   = CTFontCopyPostScriptName(ct) as String
        XCTAssertTrue(ps.contains("SymbolsNF"), "U+E702 run must use SymbolsNF, got \(ps)")
        XCTAssertFalse(ps.contains("LastResort"), "U+E702 must not fall back to LastResort")
        let glyph = ctGlyph(0xE702, ct)
        XCTAssertNotEqual(glyph, 0, "SymbolsNF glyph for U+E702 must be non-zero")
    }

    func testF0279FontCoverageViaProductionPath() throws {
        let size: CGFloat = 14
        // U+F0279 is outside BMP — surrogate pair in UTF-16 (positions 0 and 1)
        let scalar = try XCTUnwrap(Unicode.Scalar(0xF0279))
        let attr   = sessionTitleAttributedString(String(scalar), monoSize: size, color: .white)
        let ct     = try runFont(attr, utf16Position: 0)
        let ps     = CTFontCopyPostScriptName(ct) as String
        XCTAssertTrue(ps.contains("SymbolsNF"), "U+F0279 run must use SymbolsNF, got \(ps)")
        XCTAssertFalse(ps.contains("LastResort"), "U+F0279 must not fall back to LastResort")
        let glyph  = ctGlyph(0xF0279, ct)
        XCTAssertNotEqual(glyph, 0, "SymbolsNF glyph for U+F0279 must be non-zero")
    }

    func testMonoRunFontSizeViaProductionPath() throws {
        let size: CGFloat = 13
        // "ab" is two mono code units; check the first
        let attr = sessionTitleAttributedString("ab", monoSize: size, color: .white)
        let ct   = try runFont(attr, utf16Position: 0)
        XCTAssertEqual(CTFontGetSize(ct), size, accuracy: 0.01)
        let ps = CTFontCopyPostScriptName(ct) as String
        XCTAssertFalse(ps.contains("LastResort"), "mono run must not use LastResort, got \(ps)")
    }

    func testEmojiRunFontSizeViaProductionPath() throws {
        let size: CGFloat = 13
        // 🚀 U+1F680 is a surrogate pair — UTF-16 positions 0 and 1
        let attr = sessionTitleAttributedString("🚀", monoSize: size, color: .white)
        let ct   = try runFont(attr, utf16Position: 0)
        XCTAssertEqual(CTFontGetSize(ct), size, accuracy: 0.01,
            "Emoji run font size must match requested size, not default 17pt")
    }
}

// MARK: - Helpers

private func chars(_ attr: AttributedString) -> String { String(attr.characters) }

// Typesets `attr` into a CTLine and returns the CTFont CoreText chose for the
// run containing UTF-16 position `pos`. Fails the test if no run covers the position.
private func runFont(_ attr: AttributedString, utf16Position pos: Int) throws -> CTFont {
    let ns = try XCTUnwrap(try? NSAttributedString(attr, including: \.appKit))
    let line = CTLineCreateWithAttributedString(ns)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    var found: CTFont?
    for run in runs {
        let range = CTRunGetStringRange(run)
        if pos >= range.location && pos < range.location + range.length {
            found = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            break
        }
    }
    return try XCTUnwrap(found, "No CTRun covers UTF-16 position \(pos)")
}

// CGGlyph CoreText assigns to a scalar in a given CTFont; 0 = not covered.
// Allocates a buffer sized to the full UTF-16 length of the scalar (BMP = 1,
// supplementary = 2 surrogates) so CTFontGetGlyphsForCharacters never overflows.
private func ctGlyph(_ scalarValue: UInt32, _ font: CTFont) -> CGGlyph {
    guard let s = Unicode.Scalar(scalarValue) else { return 0 }
    let utf16  = Array(String(s).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
    return glyphs.first { $0 != 0 } ?? 0
}
