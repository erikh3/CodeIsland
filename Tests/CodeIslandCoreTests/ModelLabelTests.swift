import XCTest
@testable import CodeIslandCore

final class ModelLabelTests: XCTestCase {

    // MARK: - displayName: Claude ids

    func testClaudeFamilyFirstIdsBecomeFriendlyNames() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5"), "Opus 5")
    }

    func testLongContextSuffixAppends1M() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5[1m]"), "Opus 5.5 1M")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-5[1M]"), "Sonnet 5 1M")
        XCTAssertEqual(ModelLabel.displayName(for: "opus[1m]"), "Opus 1M")
    }

    func testLegacyVersionFirstClaudeIds() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-3-opus-20240229"), "Opus 3")
    }

    func testClaudeAliasesAreCapitalized() {
        XCTAssertEqual(ModelLabel.displayName(for: "opus"), "Opus")
        XCTAssertEqual(ModelLabel.displayName(for: "sonnet"), "Sonnet")
    }

    func testProviderRoutingDecorationIsStripped() {
        XCTAssertEqual(ModelLabel.displayName(for: "anthropic/claude-sonnet-4"), "Sonnet 4")
        XCTAssertEqual(
            ModelLabel.displayName(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            "Sonnet 4.5"
        )
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-4-5@20250929"), "Sonnet 4.5")
    }

    // MARK: - displayName: everything else

    func testNonClaudeIdsKeepTheirSpellingMinusDates() {
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-6-astra"), "gpt-6-astra")
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-4o-2024-08-06"), "gpt-4o")
        XCTAssertEqual(ModelLabel.displayName(for: "some-model-20250514"), "some-model")
        XCTAssertEqual(ModelLabel.displayName(for: "github-copilot/gpt-5.4"), "gpt-5.4")
    }

    func testNamesThatMerelyEndInAVersionAreNotMangled() {
        XCTAssertEqual(ModelLabel.displayName(for: "deepseek-v3"), "deepseek-v3")
        XCTAssertEqual(ModelLabel.displayName(for: "gemini-2.5-pro-preview-05-06"), "gemini-2.5-pro-preview-05-06")
        XCTAssertEqual(ModelLabel.displayName(for: "kimi-k2"), "kimi-k2")
    }

    func testUnknownClaudeShapesFallBackToTheRawId() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5-thinking"), "claude-opus-5-5-thinking")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-2.1"), "claude-2.1")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5-1-2"), "claude-opus-5-5-1-2")
    }

    func testEmptyAndPlaceholderIdsHaveNoName() {
        XCTAssertNil(ModelLabel.displayName(for: nil))
        XCTAssertNil(ModelLabel.displayName(for: ""))
        XCTAssertNil(ModelLabel.displayName(for: "   "))
        XCTAssertNil(ModelLabel.displayName(for: "<synthetic>"))
    }

    // MARK: - label

    func testLabelAppendsNormalizedEffort() {
        XCTAssertEqual(ModelLabel.label(model: "claude-opus-5-5", effort: "xhigh"), "Opus 5.5 · xhigh")
        XCTAssertEqual(ModelLabel.label(model: "gpt-5.6-sol", effort: " MAX "), "gpt-5.6-sol · max")
        XCTAssertEqual(ModelLabel.label(model: "claude-opus-5-5[1m]", effort: "high"), "Opus 5.5 1M · high")
    }

    func testLabelWithoutEffortIsJustTheName() {
        XCTAssertEqual(ModelLabel.label(model: "claude-sonnet-5", effort: nil), "Sonnet 5")
        XCTAssertEqual(ModelLabel.label(model: "claude-sonnet-5", effort: "  "), "Sonnet 5")
    }

    func testEffortAloneProducesNoLabel() {
        XCTAssertNil(ModelLabel.label(model: nil, effort: "xhigh"))
    }

    // MARK: - mergedModelId

    func testTranscriptIdDoesNotStripTheConfiguredContextVariant() {
        XCTAssertEqual(
            ModelLabel.mergedModelId(current: "claude-opus-5-5[1m]", observed: "claude-opus-5-5"),
            "claude-opus-5-5[1m]"
        )
    }

    func testARealModelSwitchReplacesTheCurrentId() {
        XCTAssertEqual(
            ModelLabel.mergedModelId(current: "claude-opus-5-5[1m]", observed: "claude-sonnet-5"),
            "claude-sonnet-5"
        )
        XCTAssertEqual(ModelLabel.mergedModelId(current: "opus", observed: "claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(ModelLabel.mergedModelId(current: nil, observed: "gpt-5.6-sol"), "gpt-5.6-sol")
    }

    // MARK: - ModelObservation

    func testObservationRejectsPlaceholdersAndNormalizesEffort() {
        XCTAssertNil(ModelObservation.from(model: "<synthetic>", effort: "xhigh"))
        XCTAssertNil(ModelObservation.from(model: nil, effort: "xhigh"))
        XCTAssertNil(ModelObservation.from(model: 42, effort: nil))
        XCTAssertEqual(
            ModelObservation.from(model: " claude-opus-5-5 ", effort: "XHigh"),
            ModelObservation(model: "claude-opus-5-5", effort: "xhigh")
        )
    }

    func testLatestInClaudeTranscriptReadsSidechainLinesNewestFirst() {
        let lines = [
            #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"find the bug"}}"#,
            #"{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","role":"assistant","content":[{"type":"text","text":"a"}]},"type":"assistant","effort":"low"}"#,
            #"{"isSidechain":true,"message":{"model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"b"}]},"type":"assistant","effort":"high"}"#,
            #"{"isSidechain":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error"}]},"type":"assistant"}"#,
        ].joined(separator: "\n")

        XCTAssertEqual(
            ModelObservation.latestInClaudeTranscript(Data(lines.utf8)),
            ModelObservation(model: "claude-sonnet-5", effort: "high")
        )
        XCTAssertNil(ModelObservation.latestInClaudeTranscript(Data()))
    }
}
