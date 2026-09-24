import Foundation

/// Model + reasoning effort seen together on one transcript line.
///
/// Claude writes both on every assistant line (`message.model` and the
/// top-level `effort`); Codex on every `turn_context`. They travel as a pair
/// because the effort belongs to that turn's model — a turn that switched to a
/// model without an effort setting must drop the old effort, not keep it.
public struct ModelObservation: Equatable, Sendable {
    public let model: String
    public let effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }

    /// Build from raw transcript values; nil for missing ids and placeholders
    /// such as Claude's `<synthetic>` (API-error stand-ins, not a real model).
    public static func from(model: Any?, effort: Any?) -> ModelObservation? {
        guard let raw = model as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return ModelObservation(model: trimmed, effort: ModelLabel.normalizedEffort(effort as? String))
    }

    /// Newest assistant model/effort in a Claude transcript blob, sidechain
    /// lines included — for a subagent's own transcript, where every line is a
    /// sidechain line. (The live tailer skips sidechain lines on purpose: in a
    /// parent transcript they belong to someone else.) Walks lines from the end
    /// and only parses the ones that mention an assistant type.
    public static func latestInClaudeTranscript(_ data: Data) -> ModelObservation? {
        let marker = Data(#""type":"assistant""#.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let observation = from(
                      model: message["model"],
                      effort: (json["perTurnEffort"] as? String) ?? (json["effort"] as? String)
                  ) else { continue }
            return observation
        }
        return nil
    }
}

/// Friendly model / reasoning-effort label for session cards.
///
/// Pure string shaping so the rules can be pinned by tests: Claude ids become
/// "Opus 5.5" / "Haiku 4.5", a `[1m]` context variant appends "1M", every other
/// id keeps its own spelling minus provider paths and date stamps, and the
/// effort rides along as a "· xhigh" suffix.
public enum ModelLabel {
    /// "Opus 5.5 · xhigh", "Opus 5.5 1M", "gpt-5.6-sol · max". nil without a model:
    /// an effort alone says nothing about what is running.
    public static func label(model: String?, effort: String?) -> String? {
        guard let name = displayName(for: model) else { return nil }
        guard let effort = normalizedEffort(effort) else { return name }
        return "\(name) · \(effort)"
    }

    /// Display name for a raw model id, or nil for empty ids and placeholders.
    public static func displayName(for model: String?) -> String? {
        guard var id = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !id.hasPrefix("<") else { return nil }

        // Claude Code spells the long-context variant as a bracket suffix
        // ("claude-opus-5-5[1m]"); the API id in the transcript never has it.
        var contextTag: String?
        if id.hasSuffix("]"), let open = id.lastIndex(of: "[") {
            let inner = id[id.index(after: open)..<id.index(before: id.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { contextTag = inner.uppercased() }
            id = String(id[..<open]).trimmingCharacters(in: .whitespaces)
        }

        let base = strippedModelId(id)
        guard !base.isEmpty else { return nil }
        let name = claudeDisplayName(base) ?? base
        return contextTag.map { "\(name) \($0)" } ?? name
    }

    /// Lowercased effort, nil when absent or blank.
    public static func normalizedEffort(_ effort: String?) -> String? {
        guard let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Which model id to keep when a transcript reports `observed`.
    ///
    /// The transcript always carries the bare API id, while hooks may report the
    /// configured `[1m]` variant of the same model. Replacing it would silently
    /// drop the "1M" tag every turn, so a decorated id of the same base survives;
    /// anything else (a real /model switch) takes the observed id.
    public static func mergedModelId(current: String?, observed: String) -> String {
        guard let current, current != observed,
              current.hasSuffix("]"), let open = current.lastIndex(of: "[") else {
            return observed
        }
        let base = current[..<open].trimmingCharacters(in: .whitespaces)
        return base == observed ? current : observed
    }

    // MARK: - Private

    /// Drop routing decoration that is not part of the model's name: provider
    /// paths ("anthropic/…", "github-copilot/…"), Bedrock region/vendor
    /// prefixes and version suffixes, Vertex "@date" suffixes, and trailing
    /// date stamps ("-20251001", "-2024-08-06").
    private static func strippedModelId(_ raw: String) -> String {
        var id = raw
        if let slash = id.lastIndex(of: "/"), id.index(after: slash) < id.endIndex {
            id = String(id[id.index(after: slash)...])
        }
        if let vendor = id.range(of: "anthropic.") {
            id = String(id[vendor.upperBound...])
        }
        if let at = id.firstIndex(of: "@") {
            id = String(id[..<at])
        }
        // Bedrock revision "-v1:0". Requires the colon so names that merely end
        // in a version ("deepseek-v3") keep it.
        if let dash = id.range(of: "-v", options: .backwards) {
            let tail = id[dash.upperBound...]
            if tail.contains(":"), tail.first?.isNumber == true,
               tail.allSatisfy({ $0.isNumber || $0 == ":" }) {
                id = String(id[..<dash.lowerBound])
            }
        }
        id = strippingDateSuffix(id)
        return id
    }

    private static func strippingDateSuffix(_ id: String) -> String {
        var parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return id }
        // "-YYYYMMDD"
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
            return parts.joined(separator: "-")
        }
        // "-YYYY-MM-DD"
        if parts.count > 3 {
            let tail = parts.suffix(3)
            let lengths = tail.map(\.count)
            if lengths == [4, 2, 2], tail.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                parts.removeLast(3)
                return parts.joined(separator: "-")
            }
        }
        return id
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-sonnet" → "Sonnet 3.5",
    /// bare aliases "opus" → "Opus". nil when the id is not a Claude family id
    /// this parser understands, so the caller falls back to the raw id.
    private static func claudeDisplayName(_ id: String) -> String? {
        let lower = id.lowercased()
        if claudeAliases.contains(lower) { return capitalized(lower) }
        guard lower.hasPrefix("claude-") else { return nil }

        let parts = lower.dropFirst("claude-".count)
            .split(separator: "-")
            .map(String.init)
        guard !parts.isEmpty else { return nil }

        var family: String?
        var version: [String] = []
        for part in parts {
            if isVersionComponent(part) {
                version.append(part)
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = part
            } else {
                // Unknown suffix ("-thinking", a codename, …): don't guess.
                return nil
            }
        }
        guard let family, version.count <= 2 else { return nil }
        let name = capitalized(family)
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// 1–2 digit numbers or dotted versions ("1.2"); 8-digit dates are already
    /// stripped, so a long all-digit run here is not a version.
    private static func isVersionComponent(_ part: String) -> Bool {
        guard !part.isEmpty, part.first?.isNumber == true,
              part.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return part.contains(".") || part.count <= 2
    }

    private static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }

    /// Claude Code's model aliases (`/model opus`); shown capitalized.
    private static let claudeAliases: Set<String> = ["opus", "sonnet", "haiku", "fable"]
}
