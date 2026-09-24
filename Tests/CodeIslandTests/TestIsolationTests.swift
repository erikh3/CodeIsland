import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// A test process must not act on the machine it runs on: no AppleScript to the
/// user's terminal, no answers read off their desktop.
final class TestIsolationTests: XCTestCase {

    // MARK: - Defaults in a test process

    func testThisProcessIsRecognisedAsATestRun() {
        XCTAssertTrue(RuntimeEnvironment.isRunningTests)
    }

    func testAppleScriptGoesNowhereUnlessATestInstallsARunner() {
        XCTAssertNil(
            AppleScriptRunner.current.evaluate("return \"ran\"", 5),
            "the default runner in a test process must not execute scripts"
        )
    }

    func testVisibilityProbeCannotSeeTheRealDesktop() throws {
        // The app really in front right now, modelled as a session's terminal.
        guard let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            throw XCTSkip("no frontmost app to compare against (headless session)")
        }
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = frontBundleId

        XCTAssertFalse(TerminalVisibilityDetector.isTerminalFrontmostForSession(session))
        XCTAssertFalse(TerminalVisibilityDetector.isSessionTabVisible(session))
    }

    func testInstalledProbeIsWhatCallersSeeAndIsRemovedAfterTheTest() {
        var ghostty = SessionSnapshot()
        ghostty.termBundleId = "com.mitchellh.ghostty"
        var iterm = SessionSnapshot()
        iterm.termBundleId = "com.googlecode.iterm2"

        installVisibilityProbe(.terminalInFront { $0.termBundleId == "com.mitchellh.ghostty" })

        XCTAssertTrue(TerminalVisibilityDetector.isTerminalFrontmostForSession(ghostty))
        XCTAssertTrue(TerminalVisibilityDetector.isSessionTabVisible(ghostty))
        XCTAssertFalse(TerminalVisibilityDetector.isTerminalFrontmostForSession(iterm))
    }
}
