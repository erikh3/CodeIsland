import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// Offscreen README screenshot harness.
///
/// Renders the real `NotchPanelView`, fed curated demo sessions, onto a
/// stylised MacBook top edge (wallpaper, menu bar, notch) and writes 2× PNGs
/// for the README. Nothing is launched: the panel goes through
/// `ImageRenderer`, so no hooks get installed and a running island is left
/// alone. Opt-in like MascotRenderHarness — skipped unless `README_SHOT_DIR`
/// is set:
///
///     README_SHOT_DIR=docs/images swift test --filter ReadmeScreenshotHarness
///     # optional, lossless (zlib 9) — trims ~25%:
///     python3 -c "import glob; from PIL import Image; [Image.open(f).save(f, optimize=True) for f in glob.glob('docs/images/readme-*.png')]"
///
/// Optional filters: `README_SHOT_ONLY=hero,approval,question`,
/// `README_SHOT_LANGS=en,zh`. Every settings key the panel reads is cleared
/// for the render (so the shots show shipped defaults) and restored after.
/// Terminal badges use the icons of whatever terminals are installed on the
/// rendering Mac (Ghostty, iTerm2, Cursor, Warp); a missing app shows its
/// badge text only.
@MainActor
final class ReadmeScreenshotHarness: XCTestCase {

    func testRenderReadmeScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["README_SHOT_DIR"] else {
            throw XCTSkip("README_SHOT_DIR not set — harness is opt-in")
        }
        let only = env["README_SHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let langs = (env["README_SHOT_LANGS"] ?? "en,zh").split(separator: ",").compactMap { ShotLang(rawValue: String($0)) }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // Views touch NSApp (e.g. QuestionBar.onAppear); make sure it exists.
        _ = NSApplication.shared

        let sandbox = DefaultsSandbox(keys: DefaultsSandbox.panelKeys)
        let savedLanguage = L10n.shared.language
        // Gate the mascots off so MascotTimeline renders one pinned frame
        // (`mascotStaticTime`) instead of a live TimelineView.
        MascotAnimationGate.shared.setPanelVisible(false)
        defer {
            MascotAnimationGate.shared.setPanelVisible(true)
            L10n.shared.language = savedLanguage
            sandbox.restore()
        }

        for lang in langs {
            L10n.shared.language = lang.rawValue
            for shot in Shot.allCases where only?.contains(shot.rawValue) ?? true {
                let demo = try await ReadmeDemo.make(shot, lang: lang)
                defer { demo.release() }

                let panel = try renderPanel(demo.state)
                let stage = Stage(panel: panel.image, panelHeight: panel.height, lang: lang, layout: shot.layout)
                let image = try XCTUnwrap(rasterize(stage), "stage render failed for \(shot)/\(lang)")
                let rep = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(outDir)/\(shot.fileName(lang)).png"))
            }
        }
    }

    /// Renders the panel exactly as PanelWindowController hosts it on a 14"
    /// MacBook Pro (1512pt wide, 185×32pt notch), then trims the transparent
    /// window area below the panel.
    private func renderPanel(_ state: AppState) throws -> (image: CGImage, height: CGFloat) {
        let view = NotchPanelView(
            appState: state,
            hasNotch: true,
            notchHeight: StageGeometry.notchHeight,
            notchW: StageGeometry.notchWidth,
            screenWidth: StageGeometry.screenWidth
        )
        .environment(\.mascotStaticTime, ReadmeDemo.mascotTime)
        .environment(\.colorScheme, .dark)
        .frame(width: StageGeometry.windowWidth, height: 900)

        let full = try XCTUnwrap(rasterize(view), "panel render failed")
        let bottom = try XCTUnwrap(Self.lastOpaqueRow(full), "panel rendered blank")
        let rows = (bottom + 2) / 2 * 2  // whole points at 2×
        let cropped = try XCTUnwrap(full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: rows)))
        return (cropped, CGFloat(rows) / 2)
    }

    /// Renders `view` at 2× into an 8-bit sRGB bitmap.
    ///
    /// `ImageRenderer.cgImage` picks its own pixel format and switches to
    /// 16-bit extended range (even HDR PQ) as soon as some content asks for
    /// it — the installed terminals' app icons do — and the down-conversion
    /// back to 8 bit is dithered, which put noise on every flat colour and
    /// tripled the file size. Drawing into our own context pins the format.
    private func rasterize<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        var result: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            draw(ctx)
            result = ctx.makeImage()
        }
        return result
    }

    /// Index of the lowest pixel row holding anything visible.
    private static func lastOpaqueRow(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        // Bitmap memory starts at the image's top row.
        for y in stride(from: h - 1, through: 0, by: -1) {
            let row = px + y * w * 4
            for x in 0..<w where row[x * 4 + 3] > 4 { return y }
        }
        return nil
    }
}

// MARK: - Shots

private enum ShotLang: String {
    case en, zh
}

private enum Shot: String, CaseIterable {
    case hero
    case approval
    case question

    func fileName(_ lang: ShotLang) -> String {
        "readme-\(rawValue)" + (lang == .zh ? "-zh" : "")
    }

    var layout: StageLayout {
        switch self {
        case .hero: return StageLayout(width: 900, bottomMargin: 76, menuItems: true)
        case .approval, .question: return StageLayout(width: 668, bottomMargin: 56, menuItems: false)
        }
    }
}

/// A demo AppState plus whatever must be torn down after rendering it
/// (pending hook continuations are resumed so no task is left hanging).
@MainActor
private struct DemoState {
    let state: AppState
    var release: () -> Void = {}
}

// MARK: - Curated demo data

@MainActor
private enum ReadmeDemo {
    /// Timeline instant every mascot is frozen at — picked so none of them
    /// is mid-blink or mid-quirk.
    static let mascotTime: Double = 5.2

    enum ID {
        static let claude = "a3e1c0d4-6f2b-4c8e-9b17-52d8e4f07c91"
        static let codex = "b7d2f5a8-1c4e-4e90-8a3b-6f1c2d9e04b3"
        static let cursor = "c5a9e3b1-8d7f-4b21-a6c4-0e3f9d2b7a58"
        static let gemini = "d8f4b2c6-3a1e-4d57-b9e8-7c2a5f1d93e6"
    }

    static func make(_ shot: Shot, lang: ShotLang) async throws -> DemoState {
        switch shot {
        case .hero: return hero(lang)
        case .approval: return try await approval(lang)
        case .question: return try await question(lang)
        }
    }

    private static func t(_ lang: ShotLang, _ en: String, _ zh: String) -> String {
        lang == .zh ? zh : en
    }

    private static func session(
        source: String,
        project: String,
        branch: String?,
        terminalBundleId: String,
        status: AgentStatus,
        startedMinutesAgo: Double
    ) -> SessionSnapshot {
        var s = SessionSnapshot(startTime: Date().addingTimeInterval(-startedMinutesAgo * 60 - 20))
        s.source = source
        s.cwd = "/Users/dev/code/\(project)"
        s.gitBranch = branch
        s.termBundleId = terminalBundleId
        s.status = status
        s.lastActivity = Date()
        return s
    }

    // MARK: Hero — session list

    private static func hero(_ lang: ShotLang) -> DemoState {
        let state = AppState()

        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .running, startedMinutesAgo: 12)
        claude.model = "claude-opus-4-5"
        let claudePrompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = claudePrompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: claudePrompt))
        claude.addRecentMessage(ChatMessage(isUser: false, text: t(lang,
            "Adding a date-range and status filter bar above the orders table.",
            "先在订单表格上方加一个日期范围和状态筛选栏。")))
        claude.currentTool = "Edit"
        claude.toolDescription = "src/components/Dashboard.tsx"
        claude.subagents["explore-1"] = SubagentState(agentId: "explore-1", agentType: "Explore")

        var codex = session(source: "codex", project: "api-server", branch: "perf/query-planner",
                            terminalBundleId: "com.googlecode.iterm2", status: .running, startedMinutesAgo: 26)
        codex.model = "gpt-5-codex"
        let codexPrompt = t(lang, "Speed up the slow /search endpoint", "优化 /search 接口的慢查询")
        let codexOutput = t(lang, "Added cost-based planner; running cargo test…", "已加入基于代价的查询规划器，正在运行 cargo test…")
        codex.lastUserPrompt = codexPrompt
        codex.addRecentMessage(ChatMessage(isUser: true, text: codexPrompt))
        codex.addRecentMessage(ChatMessage(isUser: false, text: codexOutput))
        codex.lastAssistantMessage = codexOutput
        codex.liveCodexOutput = codexOutput
        codex.currentTool = "Bash"
        codex.toolDescription = "cargo test -p planner"

        var cursor = session(source: "cursor", project: "mobile-app", branch: "fix/feed-scroll",
                             terminalBundleId: "com.todesktop.230313mzl4w4u92", status: .waitingQuestion, startedMinutesAgo: 4)
        let cursorPrompt = t(lang, "Fix the scroll jank on the feed", "修复信息流滚动卡顿")
        cursor.lastUserPrompt = cursorPrompt
        cursor.addRecentMessage(ChatMessage(isUser: true, text: cursorPrompt))
        cursor.cursorPendingQuestion = t(lang,
            "Virtualize the feed list, or switch to pagination?",
            "信息流列表改用虚拟滚动，还是换成分页？")

        var gemini = session(source: "gemini", project: "docs-site", branch: "main",
                             terminalBundleId: "dev.warp.Warp-Stable", status: .idle, startedMinutesAgo: 68)
        gemini.model = "gemini-2.5-pro"
        let geminiPrompt = t(lang, "Document the new filter API", "为新的筛选 API 补充文档")
        let geminiReply = t(lang,
            "Updated 6 pages under docs/api and fixed 3 broken links.",
            "已更新 docs/api 下的 6 个页面，并修复了 3 个失效链接。")
        gemini.lastUserPrompt = geminiPrompt
        gemini.lastAssistantMessage = geminiReply
        gemini.addRecentMessage(ChatMessage(isUser: true, text: geminiPrompt))
        gemini.addRecentMessage(ChatMessage(isUser: false, text: geminiReply))

        state.sessions = [ID.claude: claude, ID.codex: codex, ID.cursor: cursor, ID.gemini: gemini]
        state.activeSessionId = ID.claude

        // Usage footer (on by default). Set before expanding so the panel
        // never kicks off a scan of this machine's real ~/.claude history.
        var fiveHours = ClaudeUsageTotals()
        fiveHours.inputTokens = 148_000
        fiveHours.cacheCreationTokens = 274_000
        fiveHours.outputTokens = 96_400
        fiveHours.cacheReadTokens = 11_800_000
        fiveHours.messageCount = 131
        var today = ClaudeUsageTotals()
        today.inputTokens = 392_000
        today.cacheCreationTokens = 530_000
        today.outputTokens = 233_000
        today.cacheReadTokens = 29_600_000
        today.messageCount = 388
        state.claudeUsage = ClaudeUsageScanner.Snapshot(
            last5h: fiveHours,
            today: today,
            hourlyOutputTokens: [0, 3_100, 14_800, 9_200, 0, 0, 18_400, 36_500, 22_900, 12_300, 41_800, 27_600],
            scannedAt: Date()
        )
        state.surface = .sessionList
        return DemoState(state: state)
    }

    // MARK: Approval card

    private static func approval(_ lang: ShotLang) async throws -> DemoState {
        let state = AppState()
        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .waitingApproval, startedMinutesAgo: 14)
        let prompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = prompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        claude.currentTool = "Bash"
        claude.toolDescription = "npm run test -- --coverage"
        state.sessions = [ID.claude: claude]
        state.activeSessionId = ID.claude

        let event = try hookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": ID.claude,
            "cwd": "/Users/dev/code/web-app",
            "tool_name": "Bash",
            "tool_input": [
                "command": "npm run test -- --coverage",
                "description": t(lang, "Run the test suite with a coverage report", "运行测试套件并生成覆盖率报告"),
            ],
        ])
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.permissionQueue.append(PermissionRequest(event: event, continuation: continuation))
            }
        }
        await waitUntil { !state.permissionQueue.isEmpty }
        state.surface = .approvalCard(sessionId: ID.claude)
        return DemoState(state: state) {
            for request in state.permissionQueue { request.continuation.resume(returning: Data()) }
            state.permissionQueue.removeAll()
            _ = task
        }
    }

    // MARK: Question card (AskUserQuestion)

    private static func question(_ lang: ShotLang) async throws -> DemoState {
        let state = AppState()
        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .waitingQuestion, startedMinutesAgo: 9)
        let prompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = prompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        state.sessions = [ID.claude: claude]
        state.activeSessionId = ID.claude

        let questionText = t(lang, "Which state library should the dashboard use?", "仪表盘应该用哪个状态管理库？")
        let options = [
            (t(lang, "Zustand (Recommended)", "Zustand（推荐）"),
             t(lang, "Tiny hook-based store with almost no boilerplate", "轻量的 Hook 式 store，几乎零样板代码")),
            ("Redux Toolkit",
             t(lang, "Structured slices, DevTools and RTK Query built in", "结构化 slice，自带 DevTools 与 RTK Query")),
            ("React Context",
             t(lang, "Built into React; fine for state that rarely changes", "React 内置方案，适合不常变化的状态")),
        ]
        let header = t(lang, "State", "状态管理")
        let event = try hookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": ID.claude,
            "cwd": "/Users/dev/code/web-app",
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": questionText,
                    "header": header,
                    "multiSelect": false,
                    "options": options.map { ["label": $0.0, "description": $0.1] },
                ]],
            ],
        ])
        // Same item construction as AppState.handleAskUserQuestion.
        let payload = QuestionPayload(
            question: questionText,
            options: options.map(\.0),
            descriptions: options.map(\.1),
            header: header
        )
        let item = AskUserQuestionItem(payload: payload, answerKey: questionText, multiSelect: false)
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.questionQueue.append(QuestionRequest(
                    event: event,
                    question: payload,
                    continuation: continuation,
                    isFromPermission: true,
                    askUserQuestionState: AskUserQuestionState(items: [item], answers: [:])
                ))
            }
        }
        await waitUntil { !state.questionQueue.isEmpty }
        state.surface = .questionCard(sessionId: ID.claude)
        return DemoState(state: state) {
            for request in state.questionQueue { request.resolution.resumeHook(returning: Data()) }
            state.questionQueue.removeAll()
            _ = task
        }
    }

    private static func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), "HookEvent parse failed")
    }
}

// MARK: - Defaults sandbox

/// Clears the settings the panel reads so every `@AppStorage` falls back to
/// its shipped default, and puts the previous values back afterwards.
private struct DefaultsSandbox {
    private let keys: [String]
    private let saved: [String: Any]

    init(keys: [String]) {
        let defaults = UserDefaults.standard
        self.keys = keys
        var saved: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
        self.saved = saved
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static var panelKeys: [String] {
        [
            SettingsKey.appLanguage, SettingsKey.contentFontSize, SettingsKey.showAgentDetails,
            SettingsKey.smartSuppress, SettingsKey.hideWhenNoSession, SettingsKey.showToolStatus,
            SettingsKey.collapsedWidthScale, SettingsKey.hapticOnHover, SettingsKey.hapticIntensity,
            SettingsKey.sessionGroupingMode, SettingsKey.defaultSource, SettingsKey.soundEnabled,
            SettingsKey.quietHoursEnabled, SettingsKey.quietHoursStart, SettingsKey.quietHoursEnd,
            SettingsKey.autoCollapseAfterSessionJump, SettingsKey.maxVisibleSessions,
            SettingsKey.showUsageStats, SettingsKey.showClaudeQuota, SettingsKey.showGitBranch,
            SettingsKey.aiMessageLines, SettingsKey.mascotSpeed, SettingsKey.notchHeightMode,
            SettingsKey.customNotchHeight, SettingsKey.collapseOnMouseLeave, SettingsKey.maxToolHistory,
            SettingsKey.showSessionRecap, SettingsKey.showModelLabel, SettingsKey.showTaskProgress,
            SettingsKey.showProjectName, SettingsKey.autoExpandOnQuestion, SettingsKey.followUpReminderMinutes,
        ] + ShortcutAction.allCases.flatMap { action in
            [
                SettingsKey.shortcutEnabled(action.rawValue),
                SettingsKey.shortcutKeyCode(action.rawValue),
                SettingsKey.shortcutModifiers(action.rawValue),
            ]
        }
    }
}

// MARK: - Stage (stylised MacBook top edge)

private enum StageGeometry {
    // 14" MacBook Pro at its default 1512×982pt resolution.
    static let screenWidth: CGFloat = 1512
    static let notchWidth: CGFloat = 185
    static let notchHeight: CGFloat = 32
    /// PanelWindowController.panelSize: min(620, screenWidth - 40).
    static let windowWidth: CGFloat = 620
    static let bezelHeight: CGFloat = 10
    static let cornerRadius: CGFloat = 20
}

private struct StageLayout {
    let width: CGFloat
    let bottomMargin: CGFloat
    let menuItems: Bool
}

private struct Stage: View {
    let panel: CGImage
    let panelHeight: CGFloat
    let lang: ShotLang
    let layout: StageLayout

    private var height: CGFloat {
        StageGeometry.bezelHeight + panelHeight + layout.bottomMargin
    }

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper(size: CGSize(width: layout.width, height: height))
            VStack(spacing: 0) {
                Bezel()
                    .frame(height: StageGeometry.bezelHeight)
                ZStack(alignment: .top) {
                    MenuBarStrip(lang: lang, showItems: layout.menuItems)
                    PhysicalNotch()
                        .fill(Color.black)
                        .frame(width: StageGeometry.notchWidth, height: StageGeometry.notchHeight)
                    Image(decorative: panel, scale: 2)
                        .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 14)
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: layout.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: StageGeometry.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private func rgb(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}

/// Dark indigo → purple → teal with a few soft glows, rasterised by hand.
///
/// SwiftUI/CoreGraphics gradients are dithered, and that per-pixel noise
/// alone tripled the PNG size. Computing the gradient directly keeps it
/// smooth, so the image stays truecolour yet compresses well.
private struct Wallpaper: View {
    let size: CGSize

    var body: some View {
        if let image = Self.raster(size: size, scale: 2) {
            Image(decorative: image, scale: 2)
        }
    }

    private struct RGB {
        var r: Float, g: Float, b: Float
        init(_ hex: UInt32) {
            r = Float((hex >> 16) & 0xFF) / 255
            g = Float((hex >> 8) & 0xFF) / 255
            b = Float(hex & 0xFF) / 255
        }
        func mixed(with o: RGB, _ t: Float) -> RGB {
            var c = self
            c.r += (o.r - r) * t; c.g += (o.g - g) * t; c.b += (o.b - b) * t
            return c
        }
    }

    private struct Glow {
        let x: Float, y: Float, radius: Float, color: RGB, alpha: Float
    }

    static func raster(size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let fw = Float(w), fh = Float(h), longest = max(fw, fh)
        let stops = [RGB(0x1B1845), RGB(0x34205F), RGB(0x15405A)]
        let glows = [
            Glow(x: 0.03, y: 1.00, radius: 0.62, color: RGB(0x2FB5A6), alpha: 0.55),
            Glow(x: 0.97, y: 0.06, radius: 0.58, color: RGB(0xA35BE8), alpha: 0.46),
            Glow(x: 0.52, y: 0.95, radius: 0.46, color: RGB(0x5B7CFA), alpha: 0.26),
        ]
        let diag = fw * fw + fh * fh
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let py = Float(y) + 0.5
            for x in 0..<w {
                let px = Float(x) + 0.5
                // topLeading → bottomTrailing, like LinearGradient on the rect
                let t = min(max((px * fw + py * fh) / diag, 0), 1)
                var c = t < 0.5 ? stops[0].mixed(with: stops[1], t * 2) : stops[1].mixed(with: stops[2], t * 2 - 1)
                for g in glows {
                    let dx = px - g.x * fw, dy = py - g.y * fh
                    let s = min((dx * dx + dy * dy).squareRoot() / (g.radius * longest), 1)
                    let falloff = 1 - s * s * (3 - 2 * s)  // smoothstep
                    c = c.mixed(with: g.color, g.alpha * falloff)
                }
                let i = (y * w + x) * 4
                pixels[i] = UInt8(min(max(c.r * 255, 0), 255).rounded())
                pixels[i + 1] = UInt8(min(max(c.g * 255, 0), 255).rounded())
                pixels[i + 2] = UInt8(min(max(c.b * 255, 0), 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The display's top bezel: near-black with a faint lid-edge highlight.
private struct Bezel: View {
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(rgb(0x060607))
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
        }
    }
}

/// Translucent menu bar with a few stand-in items at the crop edges.
private struct MenuBarStrip: View {
    let lang: ShotLang
    let showItems: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.30))
            if showItems {
                HStack(spacing: 0) {
                    HStack(spacing: 18) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Ghostty")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 15) {
                        Image(systemName: "wifi")
                            .font(.system(size: 13, weight: .semibold))
                        Text(lang == .zh ? "周二 9:41" : "Tue 9:41")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(.horizontal, 20)
                .foregroundStyle(Color.white.opacity(0.92))
            }
        }
        .frame(height: StageGeometry.notchHeight)
    }
}

/// Notch cut-out: rounded bottom corners plus the small concave flares where
/// it meets the bezel. Sits under the panel, which grows out of it.
private struct PhysicalNotch: Shape {
    func path(in rect: CGRect) -> Path {
        let flare: CGFloat = 4
        let radius: CGFloat = 10
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + flare), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.minX - flare, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
