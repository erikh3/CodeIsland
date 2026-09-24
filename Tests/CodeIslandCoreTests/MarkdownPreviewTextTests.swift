import XCTest
@testable import CodeIslandCore

final class MarkdownPreviewTextTests: XCTestCase {
    private let reply = """
    ## Summary
    Fixed the **login** bug in `auth.ts`.

    Changes:
    - [x] token refresh checks expiry
    - [ ] manual QA

    | File | Lines |
    |------|------:|
    | auth.ts | 12 |

    ```bash
    npm test
    npm run lint
    ```
    """

    func testSingleLinePreviewCarriesNoMarkdownSyntax() {
        XCTAssertEqual(
            MarkdownPreviewText.plain(reply, singleLine: true),
            "Summary · Fixed the login bug in auth.ts. · Changes: ☑ token refresh checks expiry · ☐ manual QA"
                + " · File, Lines · auth.ts, 12 · npm test …"
        )
    }

    func testMultiLinePreviewKeepsOneLinePerBlock() {
        XCTAssertEqual(
            MarkdownPreviewText.plain(reply, singleLine: false),
            """
            Summary
            Fixed the login bug in auth.ts.
            Changes:
            ☑ token refresh checks expiry · ☐ manual QA
            File, Lines · auth.ts, 12
            npm test …
            """
        )
    }

    func testMultiLinePreviewKeepsParagraphLineBreaks() {
        XCTAssertEqual(MarkdownPreviewText.plain("one\ntwo", singleLine: false), "one\ntwo")
        XCTAssertEqual(MarkdownPreviewText.plain("one\ntwo", singleLine: true), "one two")
    }

    func testOrderedListsKeepTheirNumbersAndNestedItemsFlowInline() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("Steps:\n\n3. build\n   - debug\n4. test", singleLine: true),
            "Steps: 3. build · debug · 4. test"
        )
    }

    func testQuotesAndBreaksLoseTheirMarkers() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("> **Note** restart\n\n---\n\ndone", singleLine: true),
            "Note restart · done"
        )
    }

    func testSingleLineCodeBlockHasNoEllipsis() {
        XCTAssertEqual(MarkdownPreviewText.plain("Run:\n```\n  make  \n```", singleLine: true), "Run: make")
    }

    func testEmptyTableCellsAreSkipped() {
        XCTAssertEqual(
            MarkdownPreviewText.plain("| a | | c |\n|---|---|---|\n| 1 | 2 | |", singleLine: true),
            "a, c · 1, 2"
        )
    }

    func testStreamingFragmentsPreviewCleanly() {
        XCTAssertEqual(MarkdownPreviewText.plain("| a | b |\n|--", singleLine: true), "a, b")
        XCTAssertEqual(MarkdownPreviewText.plain("Here:\n```py", singleLine: true), "Here:")
        XCTAssertEqual(MarkdownPreviewText.plain("##", singleLine: true), "")
        XCTAssertEqual(MarkdownPreviewText.plain("- ", singleLine: true), "")
        XCTAssertEqual(MarkdownPreviewText.plain("", singleLine: false), "")
    }

    func testHeadingsStayBoldAndCodeKeepsItsCodeIntent() {
        let preview = MarkdownPreviewText.attributed(
            MarkdownBlockParser.parse("# Title\nuse `make`\n```\nnpm test\n```"),
            singleLine: true
        )
        let runs = preview.runs.map { (String(preview[$0.range].characters), $0.inlinePresentationIntent) }
        XCTAssertTrue(runs.contains { $0.0 == "Title" && $0.1?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(runs.contains { $0.0 == "make" && $0.1?.contains(.code) == true })
        XCTAssertTrue(runs.contains { $0.0 == "npm test" && $0.1?.contains(.code) == true })
        XCTAssertFalse(runs.contains { $0.0.contains(" · ") && $0.1 != nil }, "separators carry no styling")
    }

    func testInlineLinksSurviveAsLinks() {
        let preview = ChatMessageTextFormatter.markdownPreview("- see [docs](https://example.dev)", singleLine: true)
        XCTAssertEqual(String(preview.characters), "see docs")
        XCTAssertTrue(preview.runs.contains { $0.link == URL(string: "https://example.dev") })
    }

    func testPreviewCacheKeepsSingleAndMultiLineApart() {
        let text = "# A\nb"
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: true).characters), "A · b")
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: false).characters), "A\nb")
        XCTAssertEqual(String(ChatMessageTextFormatter.markdownPreview(text, singleLine: true).characters), "A · b")
    }
}
