import Foundation
import Darwin
import CodeIslandCore

/// Session discovery across several config roots of the same CLI — the primary
/// one plus the extra Claude Code / Codex / Grok roots registered in
/// Settings → Hooks (`ExtraConfigDirs`).
///
/// Discovery maps a *running process* to its transcript. With one root there
/// was nothing to decide; with several, each process is matched against the
/// root it actually uses, read from its own `CLAUDE_CONFIG_DIR` / `CODEX_HOME`
/// / `GROK_HOME`. Only when that environment cannot be read does a process fall
/// back to every known root.
extension AppState {
    /// The config-root variables of a running process, or nil when its
    /// environment cannot be read (then the root is unknown, not "default").
    nonisolated static func configRootEnvironment(for pid: pid_t) -> [String: String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let keys = Set(ConfigDirCLI.allCases.map(\.environmentKey))
        return ProcArgsParser.parse(Array(buffer.prefix(size)), environmentKeys: keys)?.environment
    }

    /// Roots whose session store may hold the transcripts of `pid`.
    nonisolated static func sessionRoots(
        forProcess pid: pid_t,
        cli: ConfigDirCLI,
        knownRoots: [String],
        defaultRoot: String
    ) -> [String] {
        let root = ExtraConfigDirs.processRoot(
            cli: cli,
            environment: configRootEnvironment(for: pid),
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path,
            defaultRoot: defaultRoot
        )
        return root.map { [$0] } ?? knownRoots
    }

    /// Root a Codex process without `$CODEX_HOME` uses.
    nonisolated static var defaultCodexRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
    }

    /// Root a Grok process without `$GROK_HOME` uses.
    nonisolated static var defaultGrokRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.grok"
    }

    /// Session stores of the extra roots, for the discovery watcher. The
    /// primary stores are listed by `discoveryWatchRoots` itself.
    nonisolated static func extraConfigDirWatchRoots() -> [(source: String, path: String)] {
        ExtraConfigDirs.load()
            .filter(\.enabled)
            .map { ($0.cli.source, "\($0.path)/\($0.cli.sessionStoreSubdirectory)") }
    }

    /// Codex roots whose state DB, rollouts and thread index may hold a given
    /// thread. `~/.codex` stays first — it is where these lookups always looked
    /// and where Codex Desktop keeps its state — followed by CodeIsland's own
    /// `$CODEX_HOME` (when launched from a shell) and the extra roots.
    nonisolated static func codexStateRoots() -> [String] {
        ExtraConfigDirs.roots(primary: defaultCodexRoot, extras: ConfigInstaller.codexHomes())
    }
}
