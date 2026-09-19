// CodeIsland pi extension
// version: v20
// OMP-compatible install

/**
 * @fileoverview CodeIsland Integration Extension for Oh My Pi / OMP.
 *
 * This is the same socket bridge as codeisland-pi.ts, but imports OMP's
 * package scope so `omp` can load it from ~/.omp/agent/extensions.
 */

import { execFile, execFileSync } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { getuid } from "node:process";
import type {
  AgentToolContext,
  AgentToolResult,
} from "@oh-my-pi/pi-agent-core";
import type {
  ExtensionAPI,
  ExtensionContext,
  ToolDefinition,
} from "@oh-my-pi/pi-coding-agent/extensibility/extensions/types";
import type {
  AskToolDetails,
  QuestionResult,
} from "@oh-my-pi/pi-coding-agent/tools/ask";
import type { ToolSession } from "@oh-my-pi/pi-coding-agent/tools";

// ── Socket / bridge constants ─────────────────────────────────────────────────

/** Unix socket path CodeIsland listens on (user-scoped). */
const userId = getuid?.() ?? 0;
const SOCKET_PATH = `/tmp/codeisland-${userId}.sock`;

/**
 * Bridge binary path. Used for blocking permission requests because Node's
 * half-close (`sock.end()`) causes NWConnection to close before the response
 * arrives on macOS; the bridge uses POSIX `shutdown(SHUT_WR)` which works.
 */
const BRIDGE_PATH = `${homedir()}/.codeisland/codeisland-bridge`;

/** Environment variable keys forwarded to CodeIsland for terminal detection. */
const ENV_KEYS = [
  "TERM_PROGRAM",
  "ITERM_SESSION_ID",
  "TERM_SESSION_ID",
  "TMUX",
  "TMUX_PANE",
  "KITTY_WINDOW_ID",
  "CMUX_SURFACE_ID",
  "CMUX_WORKSPACE_ID",
  "ZELLIJ_PANE_ID",
  "ZELLIJ_SESSION_NAME",
  "WEZTERM_PANE",
  "HERDR_ENV",
  "HERDR_PANE_ID",
  "HERDR_SOCKET_PATH",
  "HERDR_BIN_PATH",
  "__CFBundleIdentifier",
] as const;

// ── Dangerous bash patterns (mirrors permission-gate.ts) ──────────────────────

const DANGEROUS_PATTERNS: RegExp[] = [
  /\brm\s+(-rf?|--recursive)/i,
  /\bsudo\b/i,
  /\b(chmod|chown)\b.*777/i,
];

function isDangerous(command: string): boolean {
  return DANGEROUS_PATTERNS.some((p) => p.test(command));
}

// ── Environment / TTY helpers ─────────────────────────────────────────────────

/** Collects relevant terminal environment variables. */
function collectEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const key of ENV_KEYS) {
    if (process.env[key]) env[key] = process.env[key]!;
  }
  return env;
}

function herdrMetadata(env: Record<string, string>): Record<string, string> {
  const pane = env.HERDR_PANE_ID?.trim();
  const socket = env.HERDR_SOCKET_PATH?.trim();
  if (env.HERDR_ENV !== "1" || !pane || !socket) return {};
  const binary = env.HERDR_BIN_PATH?.trim();
  return {
    _herdr_pane_id: pane,
    _herdr_socket_path: socket,
    ...(binary ? { _herdr_bin_path: binary } : {}),
  };
}

/**
 * Walks the process tree upward to find the controlling TTY.
 * Cached at startup — pi's TTY does not change during a session.
 */
function detectTty(): string | null {
  try {
    let pid = process.pid;
    for (let i = 0; i < 8; i++) {
      const out = execFileSync("ps", ["-o", "tty=,ppid=", "-p", String(pid)], {
        timeout: 1000,
      })
        .toString()
        .trim();
      const [tty, ppidStr] = out.split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") {
        return tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
      }
      const ppid = parseInt(ppidStr ?? "0", 10);
      if (!ppid || ppid <= 1) break;
      pid = ppid;
    }
  } catch {}
  return null;
}

// ── Socket communication ──────────────────────────────────────────────────────

/**
 * Sends a JSON payload to the CodeIsland socket (fire-and-forget).
 * Returns `false` silently when CodeIsland is not running.
 *
 * @param payload - Event object to serialise and send.
 * @returns `true` on successful delivery, `false` otherwise.
 */
function sendToSocket(payload: object): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      const sock = connect({ path: SOCKET_PATH }, () => {
        sock.write(JSON.stringify(payload));
        sock.end();
        resolve(true);
      });
      sock.on("error", () => resolve(false));
      sock.setTimeout(3_000, () => {
        sock.destroy();
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}

/** Result of a cancellable bridge call: the response promise plus a cancel handle. */
interface CancellableBridge {
  promise: Promise<Record<string, unknown> | null>;
  cancel: () => void;
}

/**
 * Sends a JSON payload via the bridge binary and waits for CodeIsland's response.
 * Used exclusively for blocking permission/question requests.
 *
 * @param payload    - Blocking request object.
 * @param timeoutMs  - Maximum wait time in milliseconds (default 30 s).
 * @returns Parsed response JSON, or `null` on error / timeout.
 */
function sendAndWaitResponse(
  payload: object,
  timeoutMs = 30_000,
): Promise<Record<string, unknown> | null> {
  return sendAndWaitResponseCancellable(payload, timeoutMs).promise;
}

/**
 * Same as {@link sendAndWaitResponse} but exposes a `cancel()` that SIGKILLs
 * the bridge child process so the caller can abort a pending request when
 * the answer arrives from another source (e.g. the TUI dialog).
 */
function sendAndWaitResponseCancellable(
  payload: object,
  timeoutMs = 30_000,
): CancellableBridge {
  const { promise, resolve } = Promise.withResolvers<Record<string, unknown> | null>();

  if (!existsSync(BRIDGE_PATH)) {
    resolve(null);
    return { promise, cancel: () => {} };
  }

  let child: ChildProcess | undefined;
  try {
    child = execFile(
      BRIDGE_PATH,
      [],
      { timeout: timeoutMs, maxBuffer: 1_048_576 },
      (error, stdout) => {
        if (error) {
          resolve(null);
          return;
        }
        try {
          resolve(JSON.parse(stdout));
        } catch {
          resolve(null);
        }
      },
    );
    child.stdin!.write(JSON.stringify(payload));
    child.stdin!.end();
  } catch {
    resolve(null);
  }

  const cancel = () => {
    if (child && child.pid) {
      try { child.kill("SIGKILL"); } catch { /* already dead */ }
    }
    resolve(null);
  };

  return { promise, cancel };
}

// ── Event builders ────────────────────────────────────────────────────────────

/**
 * Builds the base fields required on every CodeIsland event payload.
 *
 * @param sessionId - Pi session UUID (prefixed with `"pi-"`).
 * @param cwd       - Current working directory.
 * @param extra     - Event-specific fields merged into the base.
 * @returns Complete event payload ready for `sendToSocket`.
 */
function base(
  sessionId: string,
  cwd: string,
  extra: Record<string, unknown>,
  tty: string | null,
): Record<string, unknown> {
  const env = collectEnv();
  return {
    session_id: `pi-${sessionId}`,
    _source: "pi",
    _ppid: process.pid,
    _env: env,
    ...herdrMetadata(env),
    _tty: tty,
    _server_port: 0,
    cwd,
    ...extra,
  };
}

/** Capitalises the first character of a tool name for display. */
function displayToolName(name: string): string {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

/** Extracts plain text from the last assistant message in an event.messages array. */
function extractLastAssistantText(
  messages: readonly unknown[],
): string {
  const assistants = messages.filter(
    (m): m is { role: "assistant"; content: unknown } =>
      !!m &&
      typeof m === "object" &&
      (m as { role?: string }).role === "assistant",
  );
  const last = assistants.at(-1);
  if (!last) return "";
  const content = last.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((c): c is { type: "text"; text: string } => c?.type === "text")
    .map((c) => c.text)
    .join("")
    .trim();
}

export interface AskRaceSettlement<T> {
  promise: Promise<T>;
  settle: (value: T, cancelLoser: () => void) => boolean;
}

/**
 * First-writer-wins settlement gate for the native Ask / CodeIsland race.
 *
 * JavaScript runs adjacent promise callbacks serially, so flipping the guard
 * before cancelling the loser makes settlement idempotent even when both
 * answers arrive in the same event-loop turn. Loser cancellation is best
 * effort: a cancellation cleanup failure must not replace the user's answer.
 */
export function createAskRaceSettlement<T>(): AskRaceSettlement<T> {
  const { promise, resolve } = Promise.withResolvers<T>();
  let isSettled = false;

  return {
    promise,
    settle(value, cancelLoser) {
      if (isSettled) return false;
      isSettled = true;
      try {
        cancelLoser();
      } catch {
        // Cancellation is cleanup; the winning answer remains authoritative.
      }
      resolve(value);
      return true;
    },
  };
}

interface RawQuestion {
  id: string;
  question: string;
  header?: string;
  options: { label: string; description?: string; preview?: string }[];
  multi?: boolean;
  recommended?: number;
}

export function mapAskQuestionsToCodeIsland(questions: RawQuestion[]) {
  return questions.map((question) => ({
    question: question.question,
    header: question.header || question.id,
    multiSelect: question.multi ?? false,
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description ? { description: option.description } : {}),
    })),
  }));
}

export type ClassifiedCodeIslandAskResponse =
  | { kind: "unavailable" }
  | { kind: "denied" }
  | { kind: "allowed"; updatedInput: Record<string, unknown> };

function isValidAnswerValue(value: unknown): boolean {
  if (typeof value === "string") return value.length > 0;
  return Array.isArray(value)
    && value.length > 0
    && value.every((item) => typeof item === "string" && item.length > 0);
}

export function classifyCodeIslandAskResponse(
  response: Record<string, unknown> | null,
  expectedAnswerKeys?: readonly string[],
): ClassifiedCodeIslandAskResponse {
  if (response === null) return { kind: "unavailable" };

  const decision = (
    response.hookSpecificOutput as Record<string, unknown> | undefined
  )?.decision as Record<string, unknown> | undefined;
  if (decision?.behavior === "deny") return { kind: "denied" };
  if (decision?.behavior !== "allow") return { kind: "unavailable" };

  const updatedInput = decision.updatedInput;
  if (!updatedInput || typeof updatedInput !== "object" || Array.isArray(updatedInput)) {
    return { kind: "unavailable" };
  }
  const answers = (updatedInput as Record<string, unknown>).answers;
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) {
    return { kind: "unavailable" };
  }
  const answerMap = answers as Record<string, unknown>;
  const answerValues = expectedAnswerKeys
    ? expectedAnswerKeys.map((key) => answerMap[key])
    : Object.values(answerMap);
  if (answerValues.length === 0 || answerValues.some((value) => !isValidAnswerValue(value))) {
    return { kind: "unavailable" };
  }
  return {
    kind: "allowed",
    updatedInput: updatedInput as Record<string, unknown>,
  };
}

// ── Child identity resolution ────────────────────────────────────────────────

/**
 * Discriminated union for OMP session identity.
 *
 * - `root`: top-level OMP session
 * - `subagent`: confirmed task child routed to its top-level session
 * - `unresolved`: registry lineage is incomplete; the caller should retry
 */
export type OmpSessionIdentity =
  | { kind: "root"; sessionId: string }
  | { kind: "subagent"; sessionId: string; rootSessionId: string; agentId: string; agentType: string }
  | { kind: "unresolved" };

interface OmpSessionManager {
  getSessionId(): string;
}

interface OmpRegistrySession {
  sessionManager: OmpSessionManager;
}

interface OmpAgentRef {
  id: string;
  kind: "main" | "sub" | "advisor";
  parentId?: string;
  session: OmpRegistrySession | null;
  /** Lifecycle state: running | idle (live) | parked (disposed) | aborted (killed). */
  status?: "running" | "idle" | "parked" | "aborted";
}

/** Registry lifecycle notification (subset of OMP's RegistryEvent). */
interface OmpRegistryEvent {
  type: "registered" | "status_changed" | "metadata_changed" | "removed";
  ref: OmpAgentRef;
}

interface OmpAgentRegistry {
  get(id: string): OmpAgentRef | undefined;
  list(): OmpAgentRef[];
  /** Subscribe to lifecycle changes; returns an unsubscribe handle. Absent on older OMP. */
  onChange?(listener: (event: OmpRegistryEvent) => void): () => void;
}


/** Resolves exact OMP ancestry from the process-global agent registry. */
export function resolveOmpIdentity(
  sessionManager: OmpSessionManager,
  entries: readonly Record<string, unknown>[],
  registry: OmpAgentRegistry,
): OmpSessionIdentity {
  const sessionId = sessionManager.getSessionId();
  const current = registry.list().find((ref) => ref.session?.sessionManager === sessionManager);
  if (!current) {
    const isSubagent = entries.some((entry) =>
      entry?.type === "session_init"
      && typeof entry.agent === "string"
      && entry.agent.length > 0
    );
    return isSubagent ? { kind: "unresolved" } : { kind: "root", sessionId };
  }
  if (current.kind === "main") return { kind: "root", sessionId };
  if (current.kind !== "sub") return { kind: "unresolved" };

  const agentType = entries.find((entry) =>
    entry?.type === "session_init"
    && typeof entry.agent === "string"
    && entry.agent.length > 0
  )?.agent;
  if (typeof agentType !== "string") return { kind: "unresolved" };

  const visited = new Set<string>([current.id]);
  let ancestor = current;
  while (ancestor.kind !== "main") {
    const parentId = ancestor.parentId;
    if (!parentId || visited.has(parentId)) return { kind: "unresolved" };
    visited.add(parentId);
    const parent = registry.get(parentId);
    if (!parent) return { kind: "unresolved" };
    ancestor = parent;
  }

  const rootSessionId = ancestor.session?.sessionManager.getSessionId();
  if (!rootSessionId) return { kind: "unresolved" };
  return {
    kind: "subagent",
    sessionId,
    rootSessionId,
    agentId: current.id,
    agentType,
  };
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function codeislandExtension(
  pi: ExtensionAPI,
  sendFn: (payload: object) => Promise<boolean> = sendToSocket,
) {
  const agentRegistry = pi.pi.AgentRegistry.global();

  const askToolRenderer = {
    mergeCallAndResult: true,
    renderCall(args: { questions?: RawQuestion[] }) {
      const questions = Array.isArray(args.questions) ? args.questions : [];
      const lines = questions.flatMap((question) => [
        `Ask: ${question.question}`,
        ...question.options.map((option) => `  ○ ${option.label}`),
      ]);
      return new pi.pi.Text(lines.join("\n") || "Ask", 0, 0);
    },
    renderResult(result: AgentToolResult<CompatibleAskToolDetails>) {
      const text = result.content
        .filter((content): content is { type: "text"; text: string } => content.type === "text")
        .map((content) => content.text)
        .join("\n");
      return new pi.pi.Text(text || "Ask completed", 0, 0);
    },
  };

  class ToolAbortError extends Error {
    override name = "ToolAbortError";
  }
  /** TTY path detected once at startup. */
  const tty = detectTty();

  /**
   * Session IDs for which a blocking PermissionRequest is currently in flight.
   * Non-lifecycle events for these sessions are suppressed to prevent CodeIsland's
   * "answered externally" heuristic from auto-denying while the card is visible.
   */
  const pendingPermissionSessions = new Set<string>();
  /** Sessions for which CodeIsland has already received SessionStart/SubagentStart. */
  const startedSessions = new Set<string>();
  /** Confirmed subagent identities, keyed by raw provider session ID. */
  const identityCache = new Map<string, OmpSessionIdentity & { kind: "subagent" }>();
  /** Root session currently represented by this extension process. */
  let activeRootSessionId: string | null = null;
  /**
   * Confirmed subagents we have emitted SubagentStart for, keyed by registry
   * agent id. Drives the registry-driven SubagentStop teardown below.
   */
  const subagentByAgentId = new Map<string, OmpSessionIdentity & { kind: "subagent" }>();
  /** Last cwd seen per subagent, for the SubagentStop payload. */
  const subagentCwd = new Map<string, string>();
  /** Agent ids already torn down, so a removed+parked pair cannot double-emit. */
  const stoppedAgentIds = new Set<string>();

  /**
   * Builds the complete event payload for CodeIsland.
   *
   * For confirmed subagents, stamps child metadata and `session_title` on every
   * event so HookServer can route it.  Root events carry no child markers.
   */
  function buildEvent(
    identity: OmpSessionIdentity,
    cwd: string,
    extra: Record<string, unknown>,
  ): Record<string, unknown> {
    const rawId = identity.kind !== "unresolved" ? identity.sessionId : "";
    const payload = base(rawId, cwd, extra, tty);
    if (identity.kind === "subagent") {
      payload._omp_subagent = true;
      payload._omp_parent_session_id = `pi-${identity.rootSessionId}`;
      payload._omp_agent_id = identity.agentId;
      payload._omp_agent_type = identity.agentType;
      payload.session_title = `Subagent \u00B7 ${identity.agentId}`;
    }
    return payload;
  }

  function resolveIdentityFromCtx(ctx: { sessionManager: { getSessionId(): string; getSessionFile(): string | null; getEntries(): readonly Record<string, unknown>[] } }): OmpSessionIdentity {
    const sessionId = ctx.sessionManager.getSessionId();
    const cached = identityCache.get(sessionId);
    if (cached) return cached;
    const resolved = resolveOmpIdentity(
      ctx.sessionManager,
      ctx.sessionManager.getEntries(),
      agentRegistry,
    );
    if (resolved.kind === "subagent") {
      identityCache.set(sessionId, resolved);
    }
    return resolved;
  }

  /**
   * Resolves identity and ensures the session start event has been emitted.
   * Returns `null` when identity is unresolved (caller should return early).
   */
  async function resolveAndEnsureStart(
    ctx: { sessionManager: { getSessionId(): string; getSessionFile(): string | null; getEntries(): readonly Record<string, unknown>[] }; cwd: string },
  ): Promise<{ identity: OmpSessionIdentity & { kind: "root" | "subagent" }; sid: string } | null> {
    const identity = resolveIdentityFromCtx(ctx);
    if (identity.kind === "unresolved") return null;
    await ensureSessionStarted(identity, ctx.cwd);
    const sid = `pi-${identity.sessionId}`;
    return { identity, sid };
  }

  async function ensureSessionStarted(
    identity: OmpSessionIdentity,
    cwd: string,
  ): Promise<void> {
    if (identity.kind === "unresolved") return;
    const rawId = identity.sessionId;
    const sid = `pi-${rawId}`;

    if (identity.kind === "root" && activeRootSessionId !== null && activeRootSessionId !== rawId) {
      const previousIdentity: OmpSessionIdentity = {
        kind: "root",
        sessionId: activeRootSessionId,
      };
      await sendFn(buildEvent(previousIdentity, cwd, { hook_event_name: "SessionEnd" }));
      startedSessions.delete(`pi-${activeRootSessionId}`);
      identityCache.delete(activeRootSessionId);
      activeRootSessionId = null;
    }

    if (startedSessions.has(sid)) {
      if (identity.kind === "root") activeRootSessionId = rawId;
      return;
    }

    if (identity.kind === "subagent") {
      // Record for registry-driven teardown (SubagentStop). A relaunched id
      // clears its prior stop tombstone so it can be torn down again.
      subagentByAgentId.set(identity.agentId, identity);
      subagentCwd.set(identity.agentId, cwd);
      stoppedAgentIds.delete(identity.agentId);
      await sendFn(
        buildEvent(identity, cwd, { hook_event_name: "SubagentStart" }),
      );
    } else {
      const sessionName = pi.getSessionName();
      await sendFn(
        buildEvent(identity, cwd, {
          hook_event_name: "SessionStart",
          ...(sessionName ? { session_title: sessionName } : {}),
        }),
      );
      activeRootSessionId = rawId;
    }
    startedSessions.add(sid);
  }

  /**
   * Emits SubagentStop for a subagent the registry reports as settled
   * (parked / aborted / removed). This is the authoritative teardown: it fires
   * even when the per-child `agent_end` -> Stop was never delivered (deferred,
   * parked, or hard-killed task children), which otherwise leaves the parent
   * card pinned on the "Agent" projection. Idempotent and safe to race with the
   * `agent_end` Stop path: CodeIsland tombstones the agent id on first teardown.
   */
  async function emitSubagentStop(agentId: string): Promise<void> {
    const identity = subagentByAgentId.get(agentId);
    if (!identity || stoppedAgentIds.has(agentId)) return;
    stoppedAgentIds.add(agentId);
    const cwd = subagentCwd.get(agentId) ?? process.cwd();
    await sendFn(buildEvent(identity, cwd, { hook_event_name: "SubagentStop" }));
    subagentByAgentId.delete(agentId);
    subagentCwd.delete(agentId);
    identityCache.delete(identity.sessionId);
    startedSessions.delete(`pi-${identity.sessionId}`);
  }

  // A finished task child stays registered as `idle` (revivable) and is only
  // torn down when its session is disposed (`parked`), hard-killed (`aborted`),
  // or explicitly released (`removed`). `idle` is deliberately NOT a settle
  // signal: a between-turns live subagent must keep its card. This mirrors the
  // Agent Hub roster exactly, so the island and the roster can never disagree.
  agentRegistry.onChange?.((event) => {
    const ref = event.ref;
    if (ref.kind !== "sub") return;
    const settled = event.type === "removed"
      || (event.type === "status_changed"
        && (ref.status === "parked" || ref.status === "aborted"));
    if (settled) void emitSubagentStop(ref.id);
  });

  // ── Shadow "ask" tool (#244 v3: native rendering + parallel answering) ─────
  //
  // Registers a custom "ask" that races CodeIsland against OMP's own AskTool.
  // Reusing AskTool keeps terminal rendering, navigation, timeout, speech, and
  // future OMP behavior in one implementation. The first real answer wins.

  type CompatibleQuestionResult = QuestionResult & { note?: string };
  type CompatibleAskToolDetails = AskToolDetails & {
    note?: string;
    chatRedirect?: boolean;
    questions?: string[];
    results?: CompatibleQuestionResult[];
  };

  function isPlanModeEnabled(ctx: ExtensionContext): boolean {
    const entries = ctx.sessionManager.getEntries();
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (entry?.type === "mode_change") return entry.mode === "plan";
    }
    return false;
  }

  function createNativeAskTool(ctx?: ExtensionContext) {
    const session: ToolSession = {
      cwd: ctx?.cwd ?? process.cwd(),
      hasUI: ctx?.hasUI ?? true,
      getSessionFile: () => ctx?.sessionManager.getSessionFile() ?? null,
      getSessionSpawns: () => null,
      settings: pi.pi.settings,
      getPlanModeState: () => ({
        enabled: ctx ? isPlanModeEnabled(ctx) : false,
        planFilePath: "local://PLAN.md",
      }),
    };
    return new pi.pi.AskTool(session);
  }

  function createNativeAskContext(
    ctx: ExtensionContext,
    onAbort: () => void,
  ): AgentToolContext {
    return {
      sessionManager: ctx.sessionManager,
      modelRegistry: ctx.modelRegistry,
      model: ctx.model,
      isIdle: () => ctx.isIdle(),
      hasQueuedMessages: () => ctx.hasPendingMessages(),
      abort: onAbort,
      settings: pi.pi.settings,
      ui: ctx.ui,
      hasUI: ctx.hasUI,
    };
  }

  /**
   * CodeIsland deduplicates repeated question text with `_2`, `_3`… suffixes.
   * Reproduce that keying so we can translate answers back to OMP question ids.
   */
  function computeAnswerKeys(questions: { question: string }[]): string[] {
    const used: Record<string, true> = {};
    return questions.map(({ question }) => {
      let key = question;
      if (used[key]) {
        let suffix = 2;
        while (used[`${question}_${suffix}`]) suffix += 1;
        key = `${question}_${suffix}`;
      }
      used[key] = true;
      return key;
    });
  }

  /** Converts CodeIsland's answer map into typed question results. */
  function islandAnswersToResults(
    answers: Record<string, unknown>,
    answerDetails: Record<string, unknown>,
    answerKeys: string[],
    questions: RawQuestion[],
  ): CompatibleQuestionResult[] {
    return questions.map((q, i) => {
      const answerKey = answerKeys[i];
      const value = answers[answerKey];
      const optionLabels = q.options.map((o) => o.label);
      const rawDetails = answerDetails[answerKey];
      const details = rawDetails && typeof rawDetails === "object"
        ? rawDetails as Record<string, unknown>
        : undefined;
      const detailedSelected = Array.isArray(details?.selectedOptions)
        ? details.selectedOptions.map(String)
        : undefined;
      const detailedCustomInput = typeof details?.customInput === "string"
        ? details.customInput
        : undefined;
      const hasStructuredDetails = detailedSelected !== undefined
        || detailedCustomInput !== undefined;

      let selectedOptions: string[] = [];
      let customInput: string | undefined;
      if (hasStructuredDetails) {
        selectedOptions = detailedSelected ?? [];
        customInput = detailedCustomInput;
      } else if (Array.isArray(value)) {
        const values = value.map(String);
        selectedOptions = values.filter((candidate) => optionLabels.includes(candidate));
        const customValues = values.filter((candidate) => !optionLabels.includes(candidate));
        if (customValues.length > 0) customInput = customValues.join("\n");
      } else if (typeof value === "string") {
        if (optionLabels.includes(value) || q.multi) {
          // Legacy CodeIsland versions flatten multi-select values into one string.
          // Keep that value intact rather than guessing at comma boundaries.
          selectedOptions = [value];
        } else {
          customInput = value;
        }
      }

      return {
        id: q.id,
        question: q.question,
        options: optionLabels,
        multi: q.multi ?? false,
        selectedOptions,
        ...(customInput !== undefined ? { customInput } : {}),
      };
    });
  }

  /** Mirrors built-in AskTool.formatQuestionResult for CodeIsland answers. */
  function formatQuestionResult(result: CompatibleQuestionResult): string {
    const noteSuffix = result.note ? ` (note: ${result.note})` : "";
    if (result.customInput !== undefined) {
      return `${result.id}: "${result.customInput}"${noteSuffix}`;
    }
    if (result.selectedOptions.length > 0) {
      const suffix = `${result.timedOut ? " (auto-selected after timeout)" : ""}${noteSuffix}`;
      return result.multi
        ? `${result.id}: [${result.selectedOptions.join(", ")}]${suffix}`
        : `${result.id}: ${result.selectedOptions[0]}${suffix}`;
    }
    return `${result.id}: (cancelled)${noteSuffix}`;
  }

  /** Mirrors built-in AskTool.formatSingleQuestionResponse for CodeIsland answers. */
  function formatSingleQuestionResponse(result: CompatibleQuestionResult): string {
    const parts: string[] = [];
    if (result.selectedOptions.length > 0) {
      const selectedText = result.multi
        ? `User selected: ${result.selectedOptions.join(", ")}`
        : `User selected: ${result.selectedOptions[0]}`;
      parts.push(result.timedOut ? `${selectedText} (auto-selected after timeout)` : selectedText);
    }
    if (result.customInput !== undefined) {
      parts.push(
        result.customInput.includes("\n")
          ? `User provided custom input:\n${result.customInput.split("\n").map((l: string) => `  ${l}`).join("\n")}`
          : `User provided custom input: ${result.customInput}`,
      );
    }
    if (result.note) {
      parts.push(
        result.note.includes("\n")
          ? `User added note:\n${result.note.split("\n").map((l: string) => `  ${l}`).join("\n")}`
          : `User added note: ${result.note}`,
      );
    }
    return parts.length > 0 ? parts.join("\n") : "User cancelled the selection";
  }

  /** Builds an AskTool-compatible result for answers returned by CodeIsland. */
  function buildAskResult(
    results: CompatibleQuestionResult[],
  ): AgentToolResult<CompatibleAskToolDetails> {
    if (results.length === 1) {
      const r = results[0];
      return {
        content: [{ type: "text", text: formatSingleQuestionResponse(r) }],
        details: {
          question: r.question,
          options: r.options,
          multi: r.multi,
          selectedOptions: r.selectedOptions,
          ...(r.customInput !== undefined ? { customInput: r.customInput } : {}),
          ...(r.note !== undefined ? { note: r.note } : {}),
          ...(r.timedOut ? { timedOut: true } : {}),
        },
      };
    }
    return {
      content: [{ type: "text", text: `User answers:\n${results.map(formatQuestionResult).join("\n")}` }],
      details: { results },
    };
  }

  /** Gate outcome: a winning source, a genuine failure, or user cancellation. */
  type GateOutcome =
    | { source: "island" | "tui"; result: AgentToolResult<CompatibleAskToolDetails> }
    | { source: "error"; error: unknown }
    | { source: "cancel" };

  const reservedAskOptionLabels: Record<string, true> = {
    "Other (type your own)": true,
    "Chat about this": true,
    "Next \u2192": true,
  };

  // Keep the v3 input additions for OMP 16.3.x, whose native Ask schema does
  // not yet expose header/preview even though its executor accepts the fields.
  const askOptionParameters = pi.zod.object({
    label: pi.zod.string(),
    description: pi.zod.string().optional(),
    preview: pi.zod.string().optional(),
  }).refine(
    (option) => reservedAskOptionLabels[option.label] !== true,
    { message: "Option label collides with a reserved Ask UI action" },
  );
  const askParameters = pi.zod.object({
    questions: pi.zod.array(
      pi.zod.object({
        id: pi.zod.string(),
        question: pi.zod.string(),
        header: pi.zod.string().optional(),
        options: pi.zod.array(askOptionParameters),
        multi: pi.zod.boolean().optional(),
        recommended: pi.zod.number().optional(),
      }),
    ).min(1),
  });

  // Reuse the native AskTool's LLM-facing label and description so the shadow
  // tool preserves OMP's behavioral guidance (default action, check existing
  // info first, only ask on major tradeoffs, never hand-write "Other", etc.).
  const nativeAskMetadata = createNativeAskTool();

  const askRendererFields = {
    mergeCallAndResult: askToolRenderer.mergeCallAndResult,
    renderCall: askToolRenderer.renderCall,
    renderResult: askToolRenderer.renderResult,
  };

  const askToolDefinition: ToolDefinition<
    typeof askParameters,
    CompatibleAskToolDetails
  > & {
    concurrency: "exclusive";
    mergeCallAndResult: boolean;
    strict: true;
    approval: "read";
  } = {
    name: "ask",
    label: nativeAskMetadata.label,
    description: nativeAskMetadata.description,
    parameters: askParameters,
    strict: true,
    approval: "read",
    concurrency: "exclusive",
    ...askRendererFields,
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const sessionId = ctx.sessionManager.getSessionId();
      const sid = `pi-${sessionId}`;
      const questions = params.questions;

      if (!ctx.hasUI) {
        ctx.abort();
        throw new ToolAbortError("Ask tool requires interactive mode");
      }

      const rawIdentity = resolveIdentityFromCtx(ctx);

      // Unresolved lineage means the registry has not attached the full parent chain yet.
      // Emit nothing to CodeIsland; run native Ask directly so the TUI
      // dialog still works while before_agent_start waits for resolution.
      if (rawIdentity.kind === "unresolved") {
        const nativeAsk = createNativeAskTool(ctx);
        const nativeContext = createNativeAskContext(ctx, () => undefined);
        const result = await nativeAsk.execute(toolCallId, params, signal, onUpdate, nativeContext);
        return result;
      }

      const identity = rawIdentity;
      const islandQuestions = mapAskQuestionsToCodeIsland(questions);
      const answerKeys = computeAnswerKeys(questions);

      const tuiAbort = new AbortController();
      const race = createAskRaceSettlement<GateOutcome>();

      const islandBridge = sendAndWaitResponseCancellable(
        buildEvent(identity, ctx.cwd, {
          hook_event_name: "PermissionRequest",
          tool_name: "AskUserQuestion",
          tool_input: { questions: islandQuestions },
          _pi_tool_call_id: toolCallId,
          _codeisland_native_ask_racing: true,
        }),
        86_400_000,
      );

      const handleExternalAbort = () => {
        race.settle({ source: "cancel" }, () => {
          islandBridge.cancel();
          tuiAbort.abort();
        });
      };
      if (signal?.aborted) {
        islandBridge.cancel();
        ctx.abort();
        throw new ToolAbortError("Ask tool was cancelled by the user");
      }
      signal?.addEventListener("abort", handleExternalAbort, { once: true });

      pendingPermissionSessions.add(sid);

      const islandPromise = islandBridge.promise.then(
        (response): CompatibleQuestionResult[] | null | undefined => {
          const classified = classifyCodeIslandAskResponse(response, answerKeys);
          if (classified.kind === "unavailable") return undefined;
          if (classified.kind === "denied") return null;

          const answers = (classified.updatedInput.answers ?? {}) as Record<string, unknown>;
          const answerDetails = (
            classified.updatedInput._codeislandAnswerDetails ?? {}
          ) as Record<string, unknown>;
          return islandAnswersToResults(
            answers,
            answerDetails,
            answerKeys,
            questions,
          );
        },
      );

      const nativeAsk = createNativeAskTool(ctx);
      const nativeContext = createNativeAskContext(ctx, () => undefined);
      const tuiPromise = nativeAsk.execute(
        toolCallId,
        params,
        tuiAbort.signal,
        onUpdate,
        nativeContext,
      ).catch((error: unknown): AgentToolResult<AskToolDetails> | null => {
        if (
          tuiAbort.signal.aborted
          || (error instanceof Error && error.name === "ToolAbortError")
        ) {
          return null;
        }
        throw error;
      });

      // A real answer, explicit deny, native failure, or cancellation settles
      // once and cancels the other side. Only an unavailable/invalid bridge is
      // a fallback signal that leaves OMP's native Ask UI alive.
      islandPromise.then(
        (results) => {
          if (results === null) {
            race.settle({ source: "cancel" }, () => tuiAbort.abort());
          } else if (results && results.length > 0) {
            race.settle(
              { source: "island", result: buildAskResult(results) },
              () => tuiAbort.abort(),
            );
          }
        },
        () => {
          // Bridge/parsing failure also falls back to OMP's native Ask UI.
        },
      );

      tuiPromise.then(
        (result) => {
          const outcome: GateOutcome = result
            ? { source: "tui", result }
            : { source: "cancel" };
          race.settle(outcome, () => islandBridge.cancel());
        },
        (error: unknown) => {
          race.settle({ source: "error", error }, () => islandBridge.cancel());
        },
      );

      try {
        const winner = await race.promise;
        if (winner.source === "error") throw winner.error;
        if (winner.source === "cancel") {
          ctx.abort();
          throw new ToolAbortError("Ask tool was cancelled by the user");
        }
        return winner.result;
      } finally {
        signal?.removeEventListener("abort", handleExternalAbort);
        pendingPermissionSessions.delete(sid);
      }
    },
  };
  pi.registerTool(askToolDefinition);

  // ── Session lifecycle ──────────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const identity = resolveOmpIdentity(
      ctx.sessionManager,
      ctx.sessionManager.getEntries(),
      agentRegistry,
    );
    if (identity.kind === "subagent") {
      identityCache.set(sessionId, identity);
    }
    await ensureSessionStarted(identity, ctx.cwd);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const isChild = identityCache.has(sessionId);
    if (isChild) {
      // Child shutdown: clear local caches only; no SessionEnd event.
      identityCache.delete(sessionId);
      startedSessions.delete(`pi-${sessionId}`);
      return;
    }

    const rootSessionId = activeRootSessionId ?? sessionId;
    const identity: OmpSessionIdentity = { kind: "root", sessionId: rootSessionId };
    await sendFn(
      buildEvent(identity, ctx.cwd, { hook_event_name: "SessionEnd" }),
    );
    startedSessions.delete(`pi-${rootSessionId}`);
    identityCache.delete(rootSessionId);
    activeRootSessionId = null;
  });

  pi.on("session_switch", async (_event, ctx) => {
    const identity = resolveIdentityFromCtx(ctx);
    await ensureSessionStarted(identity, ctx.cwd);
  });

  pi.on("input", async (event, ctx) => {
    if ((event as Record<string, unknown>).text?.toString().trim() !== "/clear") return;
    const sessionId = ctx.sessionManager.getSessionId();
    // Only act when the session is already known to CodeIsland — emitting
    // SessionStart for an unseen session would create a phantom card.
    if (!startedSessions.has(`pi-${sessionId}`)) return;
    // Retain the card by re-emitting SessionStart for the same root identity.
    // This clears the card's stale content without removing it from the UI.
    // startedSessions and identityCache are intentionally left intact so
    // the next lifecycle event sees the session as already started.
    const identity: OmpSessionIdentity = { kind: "root", sessionId };
    const sessionName = pi.getSessionName();
    await sendFn(
      buildEvent(identity, ctx.cwd, {
        hook_event_name: "SessionStart",
        ...(sessionName ? { session_title: sessionName } : {}),
      }),
    );
  });

  // ── Agent lifecycle ────────────────────────────────────────────────────────

  pi.on("before_agent_start", async (event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { identity, sid } = resolved;

    if (pendingPermissionSessions.has(sid)) return;

    const prompt = event.prompt ?? "";
    await sendFn(
      buildEvent(identity, ctx.cwd, {
        hook_event_name: "UserPromptSubmit",
        prompt,
      }),
    );
  });

  pi.on("agent_end", async (event, ctx) => {
    // Non-terminal turns: OMP already scheduled more work; suppress Stop.
    if ((event as Record<string, unknown>).willContinue === true) return;

    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { identity, sid } = resolved;

    if (pendingPermissionSessions.has(sid)) return;

    const lastAssistantMessage = extractLastAssistantText(event.messages);
    const sessionName = pi.getSessionName();

    await sendFn(
      buildEvent(identity, ctx.cwd, {
        hook_event_name: "Stop",
        last_assistant_message: lastAssistantMessage || undefined,
        ...(identity.kind === "root" && sessionName ? { session_title: sessionName } : {}),
      }),
    );
  });

  // ── Tool calls ─────────────────────────────────────────────────────────────

  pi.on("tool_call", async (event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { identity, sid } = resolved;
    const toolName = displayToolName(event.toolName);

    // Dangerous bash → send blocking PermissionRequest via bridge.
    if (
      event.toolName === "bash" &&
      typeof event.input.command === "string" &&
      isDangerous(event.input.command)
    ) {
      // Build a tool_input object for the PermissionRequest payload.
      const toolInput: Record<string, unknown> = { ...event.input };
      const command = event.input.command as string | undefined;
      if (command) toolInput.patterns = [command];

      pendingPermissionSessions.add(sid);

      const payload = buildEvent(identity, ctx.cwd, {
        hook_event_name: "PermissionRequest",
        tool_name: toolName,
        tool_input: toolInput,
        _pi_tool_call_id: event.toolCallId,
      });

      let response: Record<string, unknown> | null = null;
      try {
        response = await sendAndWaitResponse(payload);
      } finally {
        pendingPermissionSessions.delete(sid);
      }

      const behavior = (
        response?.hookSpecificOutput as Record<string, unknown> | undefined
      )?.decision as Record<string, unknown> | undefined;

      if (behavior?.behavior === "deny") {
        return { block: true, reason: "Blocked by CodeIsland" };
      }

      // Approved — fall through to normal PreToolUse event below.
    }

    // The non-blocking PreToolUse is emitted from `tool_execution_start` instead
    // (see below): that event carries the tool's `intent` — the short status
    // text omp shows while working — which the `tool_call` event's
    // schema-validated `input` has already had stripped. Emitting it here as
    // well would blank the intent.
    return undefined;
  });

  // Fires after `tool_call`, just before the tool executes. Unlike `tool_call`,
  // this event exposes `intent` (the model's per-call `i` summary), so it is the
  // source of the live status text CodeIsland shows while the agent works.
  pi.on("tool_execution_start", async (event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { identity, sid } = resolved;

    // A blocking permission request is mid-flight on this session — the
    // PermissionRequest already conveys the tool, so skip the status update.
    if (pendingPermissionSessions.has(sid)) return;

    const toolName = displayToolName(event.toolName);
    const args = (event.args ?? {}) as Record<string, unknown>;
    const toolInput: Record<string, unknown> = { ...args };
    if (event.toolName === "bash") {
      const command = args.command as string | undefined;
      if (command) toolInput.patterns = [command];
    }
    if (event.toolName === "edit" || event.toolName === "write") {
      const path = args.path as string | undefined;
      if (path) toolInput.file_path = path;
    }

    await sendFn(
      buildEvent(identity, ctx.cwd, {
        hook_event_name: "PreToolUse",
        tool_name: toolName,
        tool_input: toolInput,
        ...(event.intent ? { intent: event.intent } : {}),
      }),
    );
  });

  pi.on("tool_result", async (_event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { sid } = resolved;

    if (pendingPermissionSessions.has(sid)) return;

    await sendFn(
      buildEvent(resolved.identity, ctx.cwd, { hook_event_name: "PostToolUse" }),
    );
  });

  // ── Compaction ─────────────────────────────────────────────────────────────

  pi.on("session_before_compact", async (_event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    await sendFn(
      buildEvent(resolved.identity, ctx.cwd, { hook_event_name: "PreCompact" }),
    );
  });

  pi.on("session_compact", async (_event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    await sendFn(
      buildEvent(resolved.identity, ctx.cwd, { hook_event_name: "PostCompact" }),
    );
  });
}
