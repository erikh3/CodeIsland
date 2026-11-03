import SwiftUI
import CoreText
import AppKit

// MARK: - Bundled SymbolsNF font

// Cached font descriptor built once from the bundled file URL.
// CTFontDescriptor is size-independent; CTFont is created per-size from it.
private let _symbolsDescriptor: CTFontDescriptor? = {
    let url = Bundle.appModule.url(
        forResource: "SymbolsNerdFont-Regular", withExtension: "ttf",
        subdirectory: "Resources"
    ) ?? Bundle.appModule.url(
        forResource: "SymbolsNerdFont-Regular", withExtension: "ttf"
    )
    guard let url else { return nil }
    // kCTFontURLAttribute pins to the exact file, immune to user-installed fonts.
    let attrs = [kCTFontURLAttribute: url as CFURL] as CFDictionary
    let desc = CTFontDescriptorCreateWithAttributes(attrs)
    // Register once so the font is available to the process.
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    return desc
}()

// Returns a CTFont at `size` from the bundled file, or nil if unavailable.
private func symbolsFont(size: CGFloat) -> CTFont? {
    guard let desc = _symbolsDescriptor else { return nil }
    return CTFontCreateWithFontDescriptor(desc, size, nil)
}

// MARK: - Grapheme kind

private enum GlyphKind { case pua, emoji, mono }

// Classify one grapheme cluster.
// PUA: first scalar in E000–F8FF, F0000–FFFFD, 100000–10FFFD.
// Emoji: single-scalar with isEmojiPresentation, OR multi-scalar (ZWJ / VS-16
//   keycap / combined); this handles 🚀, ❤️, #️⃣, 👨‍💻, ©️, ®️.
private func glyphKind(of ch: Character) -> GlyphKind {
    guard let first = ch.unicodeScalars.first else { return .mono }
    let v = first.value
    if (v >= 0xE000  && v <= 0xF8FF)    { return .pua }
    if (v >= 0xF0000 && v <= 0xFFFFD)   { return .pua }
    if (v >= 0x100000 && v <= 0x10FFFD) { return .pua }
    let scalars = ch.unicodeScalars
    // Single-scalar emoji (🚀, 😀, ©, ®, …)
    if scalars.count == 1 && first.properties.isEmojiPresentation { return .emoji }
    // Multi-scalar: ZWJ sequence, VS-16 (U+FE0F) variation, or keycap (U+20E3).
    if scalars.count > 1 {
        let hasVS16   = scalars.contains { $0.value == 0xFE0F }
        let hasZWJ    = scalars.contains { $0.value == 0x200D }
        let hasKeycap = scalars.contains { $0.value == 0x20E3 }
        if hasVS16 || hasZWJ || hasKeycap { return .emoji }
    }
    return .mono
}

// MARK: - Leading-glyph detection

// True when the first grapheme of `text` is a PUA code point or an emoji
// grapheme (including VS-16/ZWJ/keycap sequences like #️⃣, ❤️, 👨‍💻).
func sessionTitleHasLeadingGlyph(_ text: String) -> Bool {
    guard let first = text.first else { return false }
    return glyphKind(of: first) != .mono
}

// MARK: - Attributed string builder

// Builds a single NSAttributedString for a session title with per-run fonts:
//   PUA run   → bundled SymbolsNF at monoSize (falls back to mono on load fail)
//   Emoji run → system font at monoSize (allows emoji fallback, respects size)
//   Text run  → monospacedSystemFont at monoSize
//
// hashPrefix: prepend '#' only when true AND the title has no leading glyph.
func sessionTitleAttributedString(
    _ title: String,
    monoSize: CGFloat,
    weight: Font.Weight = .bold,
    color: Color,
    hashPrefix: Bool = false
) -> AttributedString {
    let hasGlyph  = sessionTitleHasLeadingGlyph(title)
    let text      = (hashPrefix && !hasGlyph) ? "#\(title)" : title
    let monoFont  = NSFont.monospacedSystemFont(ofSize: monoSize, weight: weight.nsWeight)
    let sysFont   = NSFont.systemFont(ofSize: monoSize)   // emoji run: size-correct, system fallback
    let nsColor   = NSColor(color)
    let result    = NSMutableAttributedString()

    var runStart  = text.startIndex
    var runKind   = text.isEmpty ? GlyphKind.mono : glyphKind(of: text[runStart])

    func appendRun(upTo end: String.Index) {
        guard runStart < end else { return }
        let s = String(text[runStart..<end])
        let font: NSFont
        switch runKind {
        case .pua:   font = (symbolsFont(size: monoSize).map { $0 as NSFont }) ?? monoFont
        case .emoji: font = sysFont
        case .mono:  font = monoFont
        }
        result.append(NSAttributedString(string: s,
            attributes: [.font: font, .foregroundColor: nsColor]))
    }

    var idx = text.startIndex
    while idx < text.endIndex {
        let kind = glyphKind(of: text[idx])
        if kind != runKind {
            appendRun(upTo: idx)
            runStart = idx
            runKind  = kind
        }
        idx = text.index(after: idx)
    }
    appendRun(upTo: text.endIndex)

    return AttributedString(result)
}

// MARK: - View

// Drop-in Text replacement for session-title sites. Caller applies
// .lineLimit / .truncationMode / .frame / .layoutPriority unchanged.
// hashPrefix: true only at the trailing "#title" site.
struct SessionTitleText: View {
    let title: String
    var fontSize: CGFloat
    var weight: Font.Weight = .bold
    var color: Color = .white
    var hashPrefix: Bool = false

    var body: some View {
        Text(sessionTitleAttributedString(
            title, monoSize: fontSize, weight: weight, color: color, hashPrefix: hashPrefix
        ))
    }
}

// MARK: - Weight bridge

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}
