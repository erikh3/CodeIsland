import AppKit
import XCTest
@testable import CodeIsland

final class PanelWindowControllerTests: XCTestCase {
    func testScreenHopMotionUsesMoreVisibleTiming() {
        let motion = PanelWindowController.screenHopMotion()

        XCTAssertEqual(motion.outgoingOffset, 18)
        XCTAssertEqual(motion.incomingOffset, 30)
        XCTAssertEqual(motion.fadeOutDuration, 0.14, accuracy: 0.001)
        XCTAssertEqual(motion.incomingPauseDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.fadeInDuration, 0.34, accuracy: 0.001)
    }

    func testScreenHopFramesRetractOldFrameAndDropIntoNewFrame() {
        let oldFrame = NSRect(x: 100, y: 820, width: 420, height: 180)
        let newFrame = NSRect(x: 1800, y: 900, width: 420, height: 180)

        let frames = PanelWindowController.screenHopFrames(
            oldFrame: oldFrame,
            newFrame: newFrame
        )

        XCTAssertEqual(frames.outgoing.origin.x, oldFrame.origin.x)
        XCTAssertEqual(frames.outgoing.origin.y, oldFrame.origin.y + 18)
        XCTAssertEqual(frames.outgoing.size, oldFrame.size)

        XCTAssertEqual(frames.incoming.origin.x, newFrame.origin.x)
        XCTAssertEqual(frames.incoming.origin.y, newFrame.origin.y + 30)
        XCTAssertEqual(frames.incoming.size, newFrame.size)
    }

    // MARK: - Outside-click collapse policy

    private let panelFrame = NSRect(x: 600, y: 800, width: 420, height: 180)
    private let insideClick = NSPoint(x: 700, y: 850)
    private let outsideClick = NSPoint(x: 100, y: 100)

    func testCollapsedSurfaceNeverCollapses() {
        XCTAssertFalse(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .collapsed,
                clickLocation: outsideClick,
                panelFrame: panelFrame
            ),
            "Collapsed surface must be a no-op regardless of click location"
        )
    }

    func testInsideClickDoesNotCollapse() {
        XCTAssertFalse(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .sessionList,
                clickLocation: insideClick,
                panelFrame: panelFrame
            ),
            "Click inside panel frame must not collapse"
        )
    }

    func testApprovalCardOutsideClickIsBlocked() {
        XCTAssertFalse(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .approvalCard(sessionId: "s1"),
                clickLocation: outsideClick,
                panelFrame: panelFrame
            ),
            "Approval card must never collapse on outside click"
        )
    }

    func testApprovalCardInsideClickIsBlocked() {
        XCTAssertFalse(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .approvalCard(sessionId: "s1"),
                clickLocation: insideClick,
                panelFrame: panelFrame
            ),
            "Approval card must never collapse on inside click"
        )
    }

    func testQuestionCardOutsideClickShouldCollapse() {
        // shouldCollapseOnGlobalClick returns true for questionCard outside;
        // the monitor then routes to dismissQuestion rather than direct collapse.
        XCTAssertTrue(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .questionCard(sessionId: "s1"),
                clickLocation: outsideClick,
                panelFrame: panelFrame
            ),
            "Question card outside click must pass the gate so dismissQuestion is called"
        )
    }

    func testQuestionCardInsideClickDoesNotCollapse() {
        XCTAssertFalse(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .questionCard(sessionId: "s1"),
                clickLocation: insideClick,
                panelFrame: panelFrame
            ),
            "Question card inside click must be a no-op"
        )
    }

    func testSessionListOutsideClickShouldCollapse() {
        XCTAssertTrue(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .sessionList,
                clickLocation: outsideClick,
                panelFrame: panelFrame
            ),
            "Session list outside click must collapse"
        )
    }

    func testCompletionCardOutsideClickShouldCollapse() {
        XCTAssertTrue(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .completionCard(sessionId: "s1"),
                clickLocation: outsideClick,
                panelFrame: panelFrame
            ),
            "Completion card outside click must collapse"
        )
    }

    func testNilPanelFrameTreatedAsOutside() {
        XCTAssertTrue(
            PanelWindowController.shouldCollapseOnGlobalClick(
                surface: .sessionList,
                clickLocation: insideClick,
                panelFrame: nil
            ),
            "Nil panel frame must be treated as outside (no frame to contain the click)"
        )
    }
}
