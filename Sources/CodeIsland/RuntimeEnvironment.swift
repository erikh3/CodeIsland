import Foundation

/// Facts about the process this code is running in.
enum RuntimeEnvironment {
    /// True inside an XCTest run (`swift test`, Xcode).
    ///
    /// Code that would act on the machine the tests run on — scripting the
    /// user's terminal, reading which app is in front, rewriting
    /// `~/.codeisland/sessions.json` — checks this to pick an inert default,
    /// so a test only reaches real state when it asks for it explicitly.
    /// Xcode's runner sets `XCTestConfigurationFilePath`; `swift test` does
    /// not, but its `xctest` host has XCTest loaded, which the app never links.
    static let isRunningTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()
}
