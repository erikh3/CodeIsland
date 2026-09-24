import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CollapsedBarTests: XCTestCase {
    private func idleSession(title: String?) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/acme-client-portal"
        session.status = .idle
        session.sessionTitle = title
        session.recap = SessionRecap(text: "Rotated the API keys; waiting on your review.", createdAt: Date())
        return session
    }

    // MARK: - Recap tooltip

    func testRecapTooltipKeepsTheFolderOutWhenProjectNamesAreHidden() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: "Key rotation"), showProjectName: false)
        XCTAssertFalse(tooltip.contains("acme-client-portal"), "the folder name leaked into the tooltip")
        XCTAssertEqual(tooltip, "↻ Key rotation\nRotated the API keys; waiting on your review.")
    }

    func testRecapTooltipFallsBackToTheAgentNotTheFolder() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: nil), showProjectName: false)
        XCTAssertEqual(tooltip, "↻ Claude\nRotated the API keys; waiting on your review.")
    }

    func testRecapTooltipStillLeadsWithTheFolderByDefault() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: "Key rotation"), showProjectName: true)
        XCTAssertEqual(tooltip, "↻ acme-client-portal\nRotated the API keys; waiting on your review.")
        XCTAssertEqual(SessionMetadataStyle.collapsedRecapTooltip(for: nil, showProjectName: true), "")
    }
}
