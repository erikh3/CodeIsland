import XCTest
import SwiftUI
@testable import CodeIsland
import CodeIslandCore

final class MarkdownReplyViewTests: XCTestCase {
    // MARK: - List markers

    func testOrderedMarkersArePaddedToTheWidestNumber() {
        let list = MarkdownList(isOrdered: true, start: 9, items: Array(repeating: MarkdownListItem(blocks: []), count: 3))
        XCTAssertEqual(MarkdownListMarker.markers(for: list, depth: 0).map(\.label), [" 9.", "10.", "11."])
    }

    func testBulletGlyphFollowsNestingDepth() {
        let list = MarkdownList(isOrdered: false, start: 1, items: [MarkdownListItem(blocks: [])])
        let glyphs = (0..<4).map { MarkdownListMarker.markers(for: list, depth: $0).first?.label }
        XCTAssertEqual(glyphs, ["•", "◦", "▪", "•"])
    }

    func testCheckboxReplacesTheBulletButNotTheNumber() {
        let items = [MarkdownListItem(checkbox: .checked, blocks: []), MarkdownListItem(blocks: [])]
        let bullets = MarkdownListMarker.markers(for: MarkdownList(isOrdered: false, start: 1, items: items), depth: 0)
        XCTAssertEqual(bullets[0], MarkdownListMarker(label: nil, checkbox: .checked))
        XCTAssertEqual(bullets[1], MarkdownListMarker(label: "•", checkbox: nil))

        let ordered = MarkdownListMarker.markers(for: MarkdownList(isOrdered: true, start: 1, items: items), depth: 0)
        XCTAssertEqual(ordered[0], MarkdownListMarker(label: "1.", checkbox: .checked))
    }

    // MARK: - Code blocks

    func testShortCodeScrollsOnlyHorizontally() {
        let layout = MarkdownCodeLayout(code: "a\nb")
        XCTAssertFalse(layout.scrollsVertically)
        XCTAssertEqual(layout.text, "a\nb")
        XCTAssertEqual(layout.hiddenLines, 0)
    }

    func testLongCodeScrollsInsideACappedHeight() {
        let code = (1...(MarkdownCodeLayout.visibleLines + 1)).map(String.init).joined(separator: "\n")
        XCTAssertTrue(MarkdownCodeLayout(code: code).scrollsVertically)
    }

    func testHugeCodeIsCutToBoundLayoutCost() {
        let total = MarkdownCodeLayout.renderedLines + 25
        let layout = MarkdownCodeLayout(code: (1...total).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(layout.hiddenLines, 25)
        XCTAssertEqual(layout.text.split(separator: "\n").count, MarkdownCodeLayout.renderedLines)
    }

    // MARK: - Tables

    func testTableModelFlattensCellsRowMajorWithRules() {
        let table = MarkdownTable(
            header: ["File", "Lines"],
            alignments: [.leading, .trailing],
            rows: [["a.swift", "1"], ["b.swift", "2"]]
        )
        let model = MarkdownTableModel(table: table, tooltipThreshold: 20)
        XCTAssertEqual(model.columnCount, 2)
        XCTAssertEqual(model.cells.map { String($0.text.characters) }, ["File", "Lines", "a.swift", "1", "b.swift", "2"])
        XCTAssertEqual(model.cells.map(\.id), Array(0..<6))
        XCTAssertEqual(model.cells.map(\.isHeader), [true, true, false, false, false, false])
        XCTAssertEqual(model.cells.map(\.drawsTrailingRule), [true, false, true, false, true, false])
        XCTAssertEqual(model.cells.map(\.drawsBottomRule), [true, true, true, true, false, false])
        XCTAssertEqual(model.cells.map(\.isStriped), [false, false, false, false, true, true])
        XCTAssertEqual(model.cells[1].alignment, .trailing)
        XCTAssertEqual(model.cells[0].alignment, .leading)
    }

    func testOnlyLongCellsGetATooltip() {
        let table = MarkdownTable(header: ["short", "a **very** long cell that will be cut"], alignments: [.automatic, .automatic], rows: [])
        let model = MarkdownTableModel(table: table, tooltipThreshold: 20)
        XCTAssertNil(model.cells[0].tooltip)
        XCTAssertEqual(model.cells[1].tooltip, "a very long cell that will be cut")
    }

    func testHugeTablesAreCut() {
        let rows = Array(repeating: ["x"], count: MarkdownTableModel.renderedRows + 7)
        let model = MarkdownTableModel(table: MarkdownTable(header: ["h"], alignments: [.automatic], rows: rows), tooltipThreshold: 20)
        XCTAssertEqual(model.bodyRowCount, MarkdownTableModel.renderedRows)
        XCTAssertEqual(model.hiddenRows, 7)
        XCTAssertEqual(model.cells.count, MarkdownTableModel.renderedRows + 1)
    }

    // MARK: - Inline styling

    func testCodeSpansAreColouredAndOnlyWrappingTextGetsABackground() {
        let wrapping = IslandMarkdownInline.text("run `make` now")
        let truncating = IslandMarkdownInline.truncatingText("run `make` now")
        for (text, expectsBackground) in [(wrapping, true), (truncating, false)] {
            let code = text.runs.first { String(text[$0.range].characters) == "make" }
            XCTAssertEqual(code?.swiftUI.foregroundColor, IslandMarkdownStyle.inlineCode)
            XCTAssertEqual(code?.swiftUI.backgroundColor != nil, expectsBackground)
            let prose = text.runs.first { String(text[$0.range].characters) == "run " }
            XCTAssertNil(prose?.swiftUI.foregroundColor, "prose keeps the row's foreground style")
        }
    }

    func testPreviewsNeverCarryABackground() {
        // SwiftUI paints backgrounds of truncated runs onto the ellipsis.
        let preview = IslandMarkdownInline.preview("```sh\nnpm test\n```", singleLine: true)
        XCTAssertEqual(String(preview.characters), "npm test")
        XCTAssertTrue(preview.runs.allSatisfy { $0.swiftUI.backgroundColor == nil })
        XCTAssertTrue(preview.runs.contains { $0.swiftUI.foregroundColor == IslandMarkdownStyle.inlineCode })
    }

    // MARK: - Compact bar

    func testCodexLiveOutputSummaryFlattensMarkdown() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        session.liveCodexOutput = "## Plan\n- **read** the files\n- run `swift test`\n\n| a | b |\n|---|---|\n| 1 | 2 |"

        XCTAssertEqual(
            SessionLiveOutputDisplay.summary(for: session),
            "Plan · read the files · run swift test · a, b · 1, 2"
        )
    }
}
