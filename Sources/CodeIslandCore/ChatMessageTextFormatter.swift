import Foundation

public enum ChatMessageTextFormatter {
    private static var markdownCache: [String: AttributedString] = [:]
    private static let markdownCacheLimit = 128
    // Separate from markdownCache: inlineMarkdown() also splits fences, so the
    // same key can render differently there.
    private static var inlineSpanCache: [String: AttributedString] = [:]
    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var previewCache: [PreviewKey: AttributedString] = [:]

    private struct PreviewKey: Hashable {
        let text: String
        let singleLine: Bool
    }

    public static func displayText(for message: ChatMessage) -> AttributedString {
        message.isUser ? literalText(message.text) : inlineMarkdown(message.text)
    }

    public static func literalText(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    public static func inlineMarkdown(_ text: String) -> AttributedString {
        if let cached = markdownCache[text] { return cached }

        let result: AttributedString = text.contains("```")
            ? renderWithFencedCodeBlocks(text)
            : renderInlineOnly(text)

        if markdownCache.count >= markdownCacheLimit {
            markdownCache.removeAll(keepingCapacity: true)
        }
        markdownCache[text] = result
        return result
    }

    /// Inline spans only (bold, italic, code, links, strikethrough) with
    /// whitespace preserved — the per-block renderer for text that
    /// MarkdownBlockParser has already split out of its block syntax.
    public static func inlineSpans(_ text: String) -> AttributedString {
        cached(text, in: &inlineSpanCache) { renderInlineOnly(text) }
    }

    /// Block structure of an assistant reply. Cached because the island
    /// re-evaluates card bodies on hover and during expand animations, while
    /// the reply text itself rarely changes between those passes.
    public static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
        cached(text, in: &blockCache) { MarkdownBlockParser.parse(text) }
    }

    /// Clean, marker-free preview of a reply for line-capped rows. See
    /// MarkdownPreviewText.
    public static func markdownPreview(_ text: String, singleLine: Bool) -> AttributedString {
        cached(PreviewKey(text: text, singleLine: singleLine), in: &previewCache) {
            MarkdownPreviewText.attributed(markdownBlocks(text), singleLine: singleLine)
        }
    }

    /// Same bounded-cache policy as markdownCache: streaming replies produce
    /// a new key per chunk, so wholesale eviction at the limit is enough.
    private static func cached<Key: Hashable, Value>(
        _ key: Key,
        in cache: inout [Key: Value],
        render: () -> Value
    ) -> Value {
        if let hit = cache[key] { return hit }
        let value = render()
        if cache.count >= markdownCacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = value
        return value
    }

    /// Apple's inline-only markdown parser treats ``` as inline code delimiters, which collapses
    /// fenced code blocks and leaks the language identifier into the text (issue #101). Split the
    /// input around fence markers and render code bodies literally, preserving newlines.
    private static func renderWithFencedCodeBlocks(_ text: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var inFence = false
        var hasOutput = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let piece = inFence ? AttributedString(buffer) : renderInlineOnly(buffer)
            if hasOutput {
                result.append(AttributedString("\n"))
            }
            result.append(piece)
            hasOutput = true
            buffer = ""
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inFence.toggle()
                continue
            }
            if !buffer.isEmpty { buffer.append("\n") }
            buffer.append(line)
        }
        flush()
        return result
    }

    private static func renderInlineOnly(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }
}
