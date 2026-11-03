import XCTest
import CodeIslandCore
@testable import CodeIsland

// Tests for HerdrSubscription status mapping and label logic.
// buildChange is nonisolated static — no NW socket or subscription instance needed.
// Wire-level framing and reconnect behavior require a real socket (parent smoke layer).
final class HerdrSubscriptionTests: XCTestCase {

    // MARK: - Status mapping

    func testBlockedMapsToWaitingApproval() {
        let change = HerdrSubscription.buildChange(agentStatus: "blocked", stateLabels: nil, title: nil)
        XCTAssertEqual(change.status, .waitingApproval)
    }

    func testWorkingMapsToRunning() {
        let change = HerdrSubscription.buildChange(agentStatus: "working", stateLabels: nil, title: nil)
        XCTAssertEqual(change.status, .running)
    }

    func testIdleMapsToIdle() {
        let change = HerdrSubscription.buildChange(agentStatus: "idle", stateLabels: nil, title: nil)
        XCTAssertEqual(change.status, .idle)
    }

    func testDoneMapsToIdle() {
        let change = HerdrSubscription.buildChange(agentStatus: "done", stateLabels: nil, title: nil)
        XCTAssertEqual(change.status, .idle)
    }

    func testUnknownStatusMapsToNil() {
        let change = HerdrSubscription.buildChange(agentStatus: "starting", stateLabels: nil, title: nil)
        XCTAssertNil(change.status)
    }

    // MARK: - Label from state_labels

    func testStateLabelUsedWhenPresent() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "working",
            stateLabels: ["k": "Searching codebase"],
            title: "π ⠹ some title"
        )
        XCTAssertEqual(change.label, "Searching codebase")
    }

    func testEmptyStateLabelsValuesSkipped() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "working",
            stateLabels: ["k": ""],
            title: "π ⠹ fallback title"
        )
        // All values empty → falls through to title strip
        XCTAssertEqual(change.label, "fallback title")
    }

    func testNilStateLabelsAndNilTitleProducesNilLabel() {
        let change = HerdrSubscription.buildChange(agentStatus: "working", stateLabels: nil, title: nil)
        XCTAssertNil(change.label)
    }

    // MARK: - Terminal title label stripping

    func testTitleWithSpinnerStripped() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "working",
            stateLabels: nil,
            title: "π ⠹ Reading files"
        )
        XCTAssertEqual(change.label, "Reading files")
    }

    func testTitleWithErrorIndicatorStripped() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "blocked",
            stateLabels: nil,
            title: "π ! Awaiting permission"
        )
        XCTAssertEqual(change.label, "Awaiting permission")
    }

    func testTitleWithoutPrefixKeptAsIs() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "idle",
            stateLabels: nil,
            title: "plain title"
        )
        XCTAssertEqual(change.label, "plain title")
    }

    func testTitleReducedToEmptyByStripProducesNilLabel() {
        // Title is exactly the indicator with no remainder → nil, not empty string.
        let change = HerdrSubscription.buildChange(
            agentStatus: "working",
            stateLabels: nil,
            title: "π ⠹ "
        )
        XCTAssertNil(change.label)
    }

    // MARK: - state_labels takes precedence over title

    func testStateLabelsWinOverTitle() {
        let change = HerdrSubscription.buildChange(
            agentStatus: "working",
            stateLabels: ["phase": "Compiling"],
            title: "π ⠹ Something else"
        )
        XCTAssertEqual(change.label, "Compiling")
    }

}
