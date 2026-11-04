// CodeIsland pi extension
// version: v24
// OMP-compatible install

/**
 * @fileoverview CodeIsland Integration Extension for Oh My Pi / OMP.
 *
 * This is the same socket bridge as codeisland-pi.ts, but imports OMP's
 * package scope so `omp` can load it from ~/.omp/agent/extensions.
 * `CODEISLAND_SOCKET_PATH` overrides the socket path, as it does for the app.
 * Nothing is sent to a socket this user does not own (`socketIsOwnedByUser`).
 *
 * Subagent sessions (task, seance, Eval agent/workpool, and depth-zero clones):
 *   The root observes child sessions without loading extensions in them.
 *   Canonical parent metadata keeps merge, separate and hide behavior consistent.
 *   Named advisors show only queued/in-flight review work, not configured readiness.
 *   Completion and judge handles are not child sessions.
 *
 * Turn end (#386):
 *   `agent_end` ends one run, not the turn: OMP 17.0.2+ marks a run it goes
 *   on from (a retry, recovery, compaction, a reminder, a wait on background
 *   jobs) with `willContinue`, and the turn's Stop waits for the run that
 *   ends it. A turn the user interrupted (Esc) is sent with `stop_reason:
 *   "interrupted"`, which CodeIsland ends without the completion chime.
 */

import { execFile, execFileSync } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { existsSync, lstatSync } from "node:fs";
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
const SOCKET_PATH =
  process.env.CODEISLAND_SOCKET_PATH || `/tmp/codeisland-${userId}.sock`;

/**
 * Whether the socket at `path` is one this user owns. The default path is a
 * predictable name in /tmp, where any user can create a socket first: theirs
 * would be sent every event and could answer a permission request. `lstat`,
 * not `stat`: a symlink, even to our own socket, stays its owner's to repoint,
 * while a socket of ours in sticky /tmp is ours alone to remove.
 *
 * Exported for tests, which pass their own `lstat` and `uid`.
 */
export function socketIsOwnedByUser(
  path: string,
  lstat: (path: string) => { isSocket(): boolean; uid: number } = lstatSync,
  uid: number | undefined = getuid?.(),
): boolean {
  if (uid === undefined) return false;
  try {
    const stat = lstat(path);
    return stat.isSocket() && stat.uid === uid;
  } catch {
    return false;
  }
}

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

// ── Subagent sessions ─────────────────────────────────────────────────────────

/** The agent a session runs, as OMP reports it on `ctx.agent` (OMP 18.4+). */
export interface OmpAgentIdentity {
  kind: "main" | "sub";
  /** Agent registry id, unique in the process: `"Main"`, `"0-Explore"`… */
  id: string;
  /** Agent definition name: `"task"`, `"explore"`, `"sub"` for `/tan`… */
  name?: string;
  /** Registry id of the spawning agent; absent for a top-level session. */
  parentId?: string;
}

/** `ctx.agent`, or undefined on an OMP too old to report it (or a malformed one). */
export function ompAgentIdentity(ctx: unknown): OmpAgentIdentity | undefined {
  const agent = (ctx as { agent?: unknown } | null | undefined)?.agent;
  if (!agent || typeof agent !== "object") return undefined;
  const { kind, id, name, parentId } = agent as Record<string, unknown>;
  if ((kind !== "main" && kind !== "sub") || typeof id !== "string" || !id) return undefined;
  return {
    kind,
    id,
    ...(typeof name === "string" && name ? { name } : {}),
    ...(typeof parentId === "string" && parentId ? { parentId } : {}),
  };
}

const AGENT_CARDS_KEY = "__codeislandOmpAgentCards";

/**
 * OMP agent registry id → the CodeIsland session id of the session that agent
 * runs. Process-wide: OMP runs subagents in-process and rebinds this extension
 * to each of them, and a subagent knows its parent only by registry id. Each
 * copy of the extension registers its own session here.
 */
export function ompAgentCards(): Map<string, string> {
  const g = globalThis as typeof globalThis & { [AGENT_CARDS_KEY]?: Map<string, string> };
  return (g[AGENT_CARDS_KEY] ??= new Map());
}

interface OmpChildObserver {
  attach(ref: OmpAgentRef, agentType?: string): boolean;
  finish(agentId: string): void;
}

const CHILD_OBSERVERS_KEY = "__codeislandOmpChildObservers";

function ompChildObservers(): Map<string, OmpChildObserver> {
  const g = globalThis as typeof globalThis & { [CHILD_OBSERVERS_KEY]?: Map<string, OmpChildObserver> };
  return (g[CHILD_OBSERVERS_KEY] ??= new Map());
}

/** Fallback `agent_type` for a subagent whose agent name is unknown. */
const DEFAULT_SUBAGENT_TYPE = "subagent";

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
    if (!socketIsOwnedByUser(SOCKET_PATH)) {
      resolve(false);
      return;
    }
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

  if (!existsSync(BRIDGE_PATH) || !socketIsOwnedByUser(SOCKET_PATH)) {
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

/** An assistant message, as much of it as this extension reads. */
interface AssistantMessageFields {
  role: "assistant";
  content: unknown;
  stopReason?: unknown;
  errorMessage?: unknown;
}

/** The last assistant message in an event.messages array. */
function lastAssistant(
  messages: readonly unknown[],
): AssistantMessageFields | undefined {
  return messages
    .filter(
      (m): m is AssistantMessageFields =>
        !!m &&
        typeof m === "object" &&
        (m as { role?: string }).role === "assistant",
    )
    .at(-1);
}

/** Extracts plain text from the last assistant message in an event.messages array. */
function extractLastAssistantText(
  messages: readonly unknown[],
): string {
  const content = lastAssistant(messages)?.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((c): c is { type: "text"; text: string } => c?.type === "text")
    .map((c) => c.text)
    .join("")
    .trim();
}

/**
 * Whether the last assistant message in an event.messages array is one the
 * user cut off (Esc): OMP aborts it with the reason "Interrupted by user"
 * (USER_INTERRUPT_LABEL), kept on its `errorMessage`. OMP's own aborts, such
 * as a subagent's final `yield`, carry other reasons.
 */
export function interruptedByUser(messages: readonly unknown[]): boolean {
  const last = lastAssistant(messages);
  return last?.stopReason === "aborted" && last.errorMessage === "Interrupted by user";
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
  | { kind: "subagent"; sessionId: string; rootSessionId: string; agentId: string; agentType: string; parentAgentId: string }
  | { kind: "unresolved" };

interface OmpSessionManager {
  getSessionId(): string;
}

interface OmpRegistrySession {
  sessionManager: OmpSessionManager & { getCwd?(): string };
  subscribe?(listener: (event: Record<string, unknown>) => void): () => void;
  model?: { id: string; provider: string };
  thinkingLevel?: string;
  getAdvisorStats?(): { advisors?: { name: string; status: string; sessionId?: string; model?: { id: string; provider: string } }[] };
  isStreaming?: boolean;
  getAdvisorStatusOverview?(): { advisors: { name: string; status: string; yielded: boolean; backlog: number; isPaused: boolean }[] };
}

interface OmpAgentRef {
  id: string;
  kind: "main" | "sub" | "advisor";
  parentId?: string;
  displayName?: string;
  history?: { agent?: string };
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
  list?(): OmpAgentRef[];
  /** Subscribe to lifecycle changes; returns an unsubscribe handle. Absent on older OMP. */
  onChange?(listener: (event: OmpRegistryEvent) => void): () => void;
}

interface ObservedOmpChild {
  ref: OmpAgentRef;
  session: OmpRegistrySession;
  identity: OmpSessionIdentity & { kind: "subagent" };
  parentSessionId: string;
  cwd: string;
  active: boolean;
  tail: Promise<unknown>;
  unsubscribe: () => void;
}


/**
 * Identity of the agent the current session runs, exposed by OMP as
 * `ctx.agent` (PR #13314): whether this session is the top-level agent or a
 * subagent, plus its registry id, agent definition name, task depth and parent.
 */
export interface OmpAgentContext {
  kind: "main" | "sub";
  id: string;
  name: string;
  depth: number;
  parentId?: string;
}

/**
 * Walks the registry parent chain from `startId` up to the top-level `main`
 * agent and returns its session id. Undefined when the lineage is incomplete
 * (a parent is not yet registered), signalling the caller to retry later.
 */
function resolveRootSessionId(
  startId: string,
  registry: OmpAgentRegistry,
): string | undefined {
  const visited = new Set<string>([startId]);
  let ancestor = registry.get(startId);
  if (!ancestor) return undefined;
  while (ancestor.kind !== "main") {
    const parentId = ancestor.parentId;
    if (!parentId || visited.has(parentId)) return undefined;
    visited.add(parentId);
    const parent = registry.get(parentId);
    if (!parent) return undefined;
    ancestor = parent;
  }
  return ancestor.session?.sessionManager.getSessionId();
}

/**
 * Resolves OMP ancestry from the running agent's identity (`ctx.agent`).
 *
 * A `main` agent is the top-level session (root). A `sub` agent routes to its
 * top-level session id, resolved by walking the registry parent chain, since
 * `ctx.agent` carries only the immediate parent's registry id, not session ids.
 * Returns `unresolved` when that chain is not yet fully registered.
 */
export function resolveOmpIdentity(
  sessionManager: OmpSessionManager,
  registry: OmpAgentRegistry,
  agent: OmpAgentContext,
): OmpSessionIdentity {
  const sessionId = sessionManager.getSessionId();
  if (agent.kind === "main") return { kind: "root", sessionId };
  const rootSessionId = resolveRootSessionId(agent.id, registry);
  if (!rootSessionId) return { kind: "unresolved" };
  return {
    kind: "subagent",
    sessionId,
    rootSessionId,
    agentId: agent.id,
    agentType: agent.name,
    parentAgentId: agent.parentId ?? agent.id,
  };
}

// ── Todo → task-progress bridge ───────────────────────────────────────────────

/** Status vocabulary of OMP's `todo` tool (see pi-coding-agent tools/todo.ts). */
type OmpTodoStatus = "pending" | "in_progress" | "completed" | "abandoned" | "blocked";

/** One task row inside a todo phase, as carried by the tool result `details`. */
interface OmpTodoTask {
  content: string;
  status: OmpTodoStatus;
  blocker?: string;
}

/** A named phase of the todo list (OMP groups tasks into phases). */
interface OmpTodoPhase {
  name: string;
  tasks: OmpTodoTask[];
}

/**
 * Collapse OMP's five-state todo vocabulary onto the three states CodeIsland's
 * checklist understands (`pending` / `in_progress` / `completed`).
 *
 * - `abandoned` is settled work the agent gave up on: mapped to `completed` so
 *   it stays counted in the segmented bar's total and lets a finished list fade
 *   instead of reading as permanently stuck.
 * - `blocked` is neither done nor active: mapped to `pending`.
 */
function mapTodoStatus(status: string): "pending" | "in_progress" | "completed" {
  switch (status) {
    case "in_progress":
      return "in_progress";
    case "completed":
    case "abandoned":
      return "completed";
    default:
      return "pending";
  }
}

/**
 * Flatten OMP's phased todo state into the flat `{ todos: [...] }` snapshot that
 * CodeIsland's `TodoWrite` path already ingests (→ a full list replace).
 *
 * OMP's `todo` tool is op-based (`init` / `start` / `done` / …) and sends only
 * one op per call, but every result carries the whole post-op state in
 * `details.phases`, so forwarding that snapshot keeps CodeIsland in sync without
 * replaying individual ops. Multi-phase lists prefix the phase name onto each
 * task (`Phase: task`) to preserve the grouping the TUI shows; a single phase
 * (the default `Tasks` bucket for a flat `items` list) is left bare.
 *
 * An `init` with no items (or any op that clears all tasks) yields
 * `details.phases = []`. Returning `{ todos: [] }` for that case lets CodeIsland
 * clear the progress bar, rather than leaving stale items from a prior list.
 * Only `undefined` (tool has never run / details absent) returns `null` to
 * signal "nothing to forward".
 */
export function ompTodoSnapshot(
  phases: readonly OmpTodoPhase[] | undefined,
): { todos: { content: string; status: string }[] } | null {
  if (phases === undefined) return null;
  if (phases.length === 0) return { todos: [] };
  const multiPhase = phases.length > 1;
  const todos = phases.flatMap((phase) =>
    phase.tasks.map((task) => ({
      content: multiPhase && phase.name ? `${phase.name}: ${task.content}` : task.content,
      status: mapTodoStatus(task.status),
    })),
  );
  return { todos };
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function codeislandExtension(
  pi: ExtensionAPI,
  sendFn: (payload: object) => Promise<boolean> = sendToSocket,
) {
  const agentRegistry: OmpAgentRegistry | null = (pi.pi as { AgentRegistry?: { global?: () => OmpAgentRegistry } } | undefined)?.AgentRegistry?.global?.() ?? null;

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
  /** A turn's latest reply, per session, while OMP goes on with it (#386). */
  const continuedReplies = new Map<string, string>();
  const observedChildren = new Map<string, ObservedOmpChild>();
  const observedAdvisors = new Map<string, ObservedOmpChild>();
  const observerSubscriptions: (() => void)[] = [];
  let observerRootId: string | undefined;

  function childPayload(child: ObservedOmpChild, extra: Record<string, unknown>) {
    return {
      ...buildEvent(child.identity, child.cwd, extra),
      _parent_session_id: `pi-${child.parentSessionId}`,
      ...(child.session.model ? { model: `${child.session.model.provider}/${child.session.model.id}` } : {}),
      ...(child.session.thinkingLevel ? { reasoning_effort: child.session.thinkingLevel } : {}),
    };
  }

  function enqueueChild(child: ObservedOmpChild, extra: Record<string, unknown>) {
    child.tail = child.tail.then(() => sendFn(childPayload(child, extra)));
  }

  function startChildRun(child: ObservedOmpChild) {
    if (child.active) return;
    child.active = true;
    enqueueChild(child, { hook_event_name: "SubagentStart" });
  }

  function finishChildRun(child: ObservedOmpChild, messages: readonly unknown[] = []) {
    if (!child.active) return;
    child.active = false;
    enqueueChild(child, {
      hook_event_name: "Stop",
      last_assistant_message: extractLastAssistantText(messages) || undefined,
      ...(interruptedByUser(messages) ? { stop_reason: "interrupted" } : {}),
    });
  }

  function removeObservedChild(agentId: string) {
    const child = observedChildren.get(agentId);
    if (!child) return;
    child.unsubscribe();
    observedChildren.delete(agentId);
    for (const [key, advisor] of observedAdvisors) {
      if (advisor.ref.parentId !== agentId) continue;
      finishChildRun(advisor);
      enqueueChild(advisor, { hook_event_name: "SessionEnd" });
      observedAdvisors.delete(key);
    }
    enqueueChild(child, { hook_event_name: "SubagentStop" });
    enqueueChild(child, { hook_event_name: "SessionEnd" });
  }

  function observeChildEvent(child: ObservedOmpChild, event: Record<string, unknown>) {
    if (observedChildren.get(child.ref.id) !== child) return;
    switch (event.type) {
      case "agent_start":
        startChildRun(child);
        enqueueChild(child, { hook_event_name: "UserPromptSubmit" });
        break;
      case "tool_execution_start": {
        if (!child.active) return;
        const name = typeof event.toolName === "string" ? event.toolName : "";
        const input = event.args && typeof event.args === "object" ? { ...event.args } : {};
        enqueueChild(child, {
          hook_event_name: "PreToolUse",
          tool_name: displayToolName(name),
          tool_input: input,
          tool_use_id: event.toolCallId,
          ...(event.intent ? { intent: event.intent } : {}),
        });
        break;
      }
      case "tool_execution_end":
        if (!child.active) return;
        enqueueChild(child, {
          hook_event_name: event.isError === true ? "PostToolUseFailure" : "PostToolUse",
          tool_name: typeof event.toolName === "string" ? displayToolName(event.toolName) : undefined,
          tool_use_id: event.toolCallId,
          is_error: event.isError === true,
        });
        break;
      case "agent_end":
        if (event.isTerminal !== false) finishChildRun(child, Array.isArray(event.messages) ? event.messages : []);
        break;
      case "auto_compaction_start":
      case "manual_compaction_start":
        if (child.active) enqueueChild(child, { hook_event_name: "PreCompact" });
        break;
      case "auto_compaction_end":
      case "manual_compaction_end":
        if (child.active) enqueueChild(child, { hook_event_name: "PostCompact" });
        break;
    }
    syncAdvisors(child.ref.id, child.session);
  }

  function attachObservedChild(ref: OmpAgentRef, agentType?: string): boolean {
    if (!agentRegistry || !observerRootId || ref.kind === "main" || !ref.session?.subscribe) return false;
    if (ref.status === "parked" || ref.status === "aborted") return false;
    const root = resolveRootSessionId(ref.id, agentRegistry);
    if (root !== activeRootSessionId) return false;
    const existing = observedChildren.get(ref.id);
    if (existing?.session === ref.session) {
      if (agentType) existing.identity.agentType = agentType;
      return true;
    }
    if (existing) removeObservedChild(ref.id);
    const parentId = ref.parentId;
    if (!parentId) return false;
    const parentSessionId = agentRegistry.get(parentId)?.session?.sessionManager.getSessionId()
      ?? ompAgentCards().get(parentId);
    if (!parentSessionId) return false;
    const session = ref.session;
    const subscribe = session.subscribe;
    if (!subscribe) return false;
    const sessionId = session.sessionManager.getSessionId();
    if (sessionId === parentSessionId) return false;
    ompAgentCards().set(ref.id, sessionId);
    const child = {
      ref, session,
      identity: { kind: "subagent" as const, sessionId, rootSessionId: root, agentId: ref.id,
        agentType: agentType ?? ref.history?.agent ?? ref.displayName ?? DEFAULT_SUBAGENT_TYPE,
        parentAgentId: parentId },
      parentSessionId,
      cwd: session.sessionManager.getCwd?.() ?? process.cwd(),
      active: false,
      tail: Promise.resolve() as Promise<unknown>,
      unsubscribe: () => {},
    };
    observedChildren.set(ref.id, child);
    child.unsubscribe = subscribe.call(session, event => observeChildEvent(child, event));
    if (ref.status === "running") startChildRun(child);
    return true;
  }

  function syncAdvisors(ownerId: string, owner: OmpRegistrySession) {
    const overview = owner.getAdvisorStatusOverview?.();
    if (!overview) return;
    const present = new Set<string>();
    for (const advisor of overview.advisors) {
      const key = `${ownerId}/${advisor.name}`;
      const reviewing = advisor.status === "running" && !advisor.isPaused && advisor.backlog > 0;
      const existing = observedAdvisors.get(key);
      present.add(key);
      if (!reviewing) {
        if (existing) finishChildRun(existing);
        continue;
      }
      if (existing) {
        startChildRun(existing);
        continue;
      }
      const stats = owner.getAdvisorStats?.().advisors?.find(entry => entry.name === advisor.name);
      if (!stats?.sessionId || !activeRootSessionId) continue;
      const parentSessionId = owner.sessionManager.getSessionId();
      const sessionId = stats.sessionId;
      const child: ObservedOmpChild = {
        ref: { id: key, kind: "advisor", parentId: ownerId, session: null },
        session: { sessionManager: { getSessionId: () => sessionId }, model: stats.model },
        identity: { kind: "subagent", sessionId, rootSessionId: activeRootSessionId,
          agentId: key, agentType: `advisor: ${advisor.name}`, parentAgentId: ownerId },
        parentSessionId, cwd: owner.sessionManager.getCwd?.() ?? process.cwd(),
        active: false, tail: Promise.resolve(), unsubscribe: () => {},
      };
      observedAdvisors.set(key, child);
      startChildRun(child);
    }
    for (const [key, child] of observedAdvisors) {
      if (child.ref.parentId !== ownerId || present.has(key)) continue;
      finishChildRun(child);
      enqueueChild(child, { hook_event_name: "SessionEnd" });
      observedAdvisors.delete(key);
    }
  }

  function startChildObserver(agentId: string) {
    if (!agentRegistry || observerRootId === agentId) return;
    void stopChildObserver();
    observerRootId = agentId;
    ompChildObservers().set(agentId, {
      attach: attachObservedChild,
      finish(id) {
        const child = observedChildren.get(id);
        if (child && child.session.isStreaming !== true) finishChildRun(child);
      },
    });
    observerSubscriptions.push(agentRegistry.onChange?.(event => {
      if (event.type === "removed" || event.ref.status === "parked" || event.ref.status === "aborted") {
        removeObservedChild(event.ref.id);
      } else {
        attachObservedChild(event.ref);
      }
    }) ?? (() => {}));
    // Each parent extension forwards its own scoped task bus below; nested
    // children do not publish to the root extension's session bus.
    for (const ref of agentRegistry.list?.() ?? []) attachObservedChild(ref);
    const root = agentRegistry.get(agentId)?.session;
    if (root?.subscribe) {
      observerSubscriptions.push(root.subscribe(event => {
        if (["agent_start", "turn_end", "agent_end", "advisor_cost_changed", "advisor_yielded", "config_warnings_changed"].includes(String(event.type))) {
          syncAdvisors(agentId, root);
        }
      }));
      syncAdvisors(agentId, root);
    }
  }

  async function stopChildObserver() {
    for (const unsubscribe of observerSubscriptions.splice(0)) unsubscribe();
    if (observerRootId) ompChildObservers().delete(observerRootId);
    observerRootId = undefined;
    const draining = [...observedChildren.values(), ...observedAdvisors.values()];
    for (const id of observedChildren.keys()) removeObservedChild(id);
    for (const child of observedAdvisors.values()) {
      finishChildRun(child);
      enqueueChild(child, { hook_event_name: "SessionEnd" });
    }
    observedAdvisors.clear();
    await Promise.all(draining.map(child => child.tail));
  }

  /**
   * Builds the complete event payload for CodeIsland.
   *
   * For confirmed subagents, stamps `_parent_session_id` and `agent_type` so
   * HookServer's SubsessionRouter routes via DeclaredSubsession. The child's
   * card id (derived from `session_id`) becomes the `agent_id` subagent row
   * once the router folds the payload. Root events carry none of these fields.
   */
  function buildEvent(
    identity: OmpSessionIdentity,
    cwd: string,
    extra: Record<string, unknown>,
  ): Record<string, unknown> {
    const rawId = identity.kind !== "unresolved" ? identity.sessionId : "";
    const payload = base(rawId, cwd, extra, tty);
    if (identity.kind === "subagent") {
      // _parent_session_id: immediate parent session (the canonical DeclaredSubsession
      // key HookServer routes on). For depth-1 subagents this is the root; for deeper
      // nesting it is the direct parent. Falls back to rootSessionId when the parent
      // has already deregistered from ompAgentCards (e.g. a cached subagent after
      // parent shutdown).
      const parentSid = agentRegistry?.get(identity.parentAgentId)?.session?.sessionManager.getSessionId()
        ?? ompAgentCards().get(identity.parentAgentId)
        ?? identity.rootSessionId;
      payload._parent_session_id = `pi-${parentSid}`;
      payload.agent_type = identity.agentType;
      payload.session_title = `Subagent \u00B7 ${identity.agentId}`;
    }
    return payload;
  }

  /**
   * Resolves session identity using the process-wide ompAgentCards map when
   * no AgentRegistry is available (e.g. in tests or older OMP versions).
   * Registers the current session in the cards map so peers can look it up.
   */
  function resolveViaCards(
    sessionManager: OmpSessionManager,
    agent: OmpAgentContext,
  ): OmpSessionIdentity {
    const sessionId = sessionManager.getSessionId();
    // Register so that child sessions can resolve this session as their parent.
    ompAgentCards().set(agent.id, sessionId);
    if (agent.kind === "main") return { kind: "root", sessionId };
    const parentId = agent.parentId;
    if (!parentId) return { kind: "unresolved" };
    const parentSid = ompAgentCards().get(parentId);
    if (!parentSid) return { kind: "unresolved" };
    // Self-referential: advisor working within the same session — treat as root.
    if (parentSid === sessionId) return { kind: "root", sessionId };
    return {
      kind: "subagent",
      sessionId,
      rootSessionId: parentSid,
      agentId: agent.id,
      agentType: agent.name,
      parentAgentId: parentId,
    };
  }

  function resolveIdentityFromCtx(ctx: { sessionManager: { getSessionId(): string }; agent?: OmpAgentContext }): OmpSessionIdentity {
    const sessionId = ctx.sessionManager.getSessionId();
    const agent = ctx.agent;
    if (!agent) {
      // OMP version too old to report ctx.agent — treat as root, skip cards.
      return { kind: "root", sessionId };
    }
    // Advisor tools use the primary runner, not a child session.
    // Named advisor roster state is observed separately by the parent.
    if (agent.id === "advisor" && agent.name === "advisor") return { kind: "unresolved" };
    // Always register in the shared cards map so sibling sessions can find us.
    ompAgentCards().set(agent.id, sessionId);
    const cached = identityCache.get(sessionId);
    if (cached) return cached;
    const resolved = agentRegistry !== null
      ? resolveOmpIdentity(ctx.sessionManager, agentRegistry, agent)
      : resolveViaCards(ctx.sessionManager, agent);
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
    ctx: { sessionManager: { getSessionId(): string }; agent?: OmpAgentContext; cwd: string },
    blocking = false,
  ): Promise<{ identity: OmpSessionIdentity & { kind: "root" | "subagent" }; sid: string } | null> {
    const identity = resolveIdentityFromCtx(ctx);
    if (identity.kind === "unresolved") return null;
    if (identity.kind === "root") {
      await ensureSessionStarted(identity, ctx.cwd);
      if (ctx.agent) startChildObserver(ctx.agent.id);
    } else {
      const ref = agentRegistry?.get(identity.agentId);
      let observer: OmpChildObserver | undefined;
      if (ref) {
        for (const owner of ompChildObservers().values()) {
          if (owner.attach(ref, identity.agentType)) { observer = owner; break; }
        }
      }
      if (observer) {
        if (!blocking) return null;
      } else {
        await ensureSessionStarted(identity, ctx.cwd);
      }
    }
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
      await stopChildObserver();
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
    await sendFn(buildEvent(identity, cwd, { hook_event_name: "SessionEnd" }));
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
  const unsubscribeLegacyRegistry = agentRegistry?.onChange?.((event) => {
    const ref = event.ref;
    if (ref.kind !== "sub") return;
    const settled = event.type === "removed"
      || (event.type === "status_changed"
        && (ref.status === "parked" || ref.status === "aborted"));
    if (settled) void emitSubagentStop(ref.id);
  });

  const unsubscribeChildLifecycle = pi.events?.on("task:subagent:lifecycle", data => {
    if (!data || typeof data !== "object" || !agentRegistry) return;
    const { id, agent, status } = data as Record<string, unknown>;
    if (typeof id !== "string") return;
    if (status === "started") {
      const ref = agentRegistry.get(id);
      if (!ref) return;
      for (const observer of ompChildObservers().values()) {
        if (observer.attach(ref, typeof agent === "string" ? agent : undefined)) break;
      }
    } else if (status === "completed" || status === "failed" || status === "aborted") {
      for (const observer of ompChildObservers().values()) observer.finish(id);
    }
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
      advertiseHeadlessAsk: ctx?.agent?.kind === "sub",
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
    mergeCallAndResult?: boolean;
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
        return createNativeAskTool(ctx).execute(toolCallId, params, signal, onUpdate, createNativeAskContext(ctx, () => ctx.abort()));
      }

      const rawIdentity = resolveIdentityFromCtx(ctx);
      if (rawIdentity.kind === "subagent") await resolveAndEnsureStart(ctx, true);

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
    // resolveAndEnsureStart resolves via ctx.agent (falling back to the
    // registry), caches confirmed subagents, and emits the start event.
    await resolveAndEnsureStart(ctx);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const isChild = identityCache.has(sessionId);
    // Always clean up this session's entry in the shared cards map, guarding
    // against a newer session that has already claimed the same registry id.
    const agentCtx = (ctx as unknown as { agent?: OmpAgentContext }).agent;
    const agentId = agentCtx?.id;
    unsubscribeChildLifecycle?.();
    unsubscribeLegacyRegistry?.();
    if (agentId && ompAgentCards().get(agentId) === sessionId) {
      ompAgentCards().delete(agentId);
    }
    if (isChild) {
      // When no AgentRegistry is available, emit SubagentStop here since the
      // registry's onChange (which normally drives teardown) never fires.
      // emitSubagentStop is idempotent, so this is safe if onChange fires later.
      if (agentRegistry === null && agentId) await emitSubagentStop(agentId);
      identityCache.delete(sessionId);
      startedSessions.delete(`pi-${sessionId}`);
      continuedReplies.delete(`pi-${sessionId}`);
      return;
    }

    await stopChildObserver();
    const rootSessionId = activeRootSessionId ?? sessionId;
    const identity: OmpSessionIdentity = { kind: "root", sessionId: rootSessionId };
    await sendFn(
      buildEvent(identity, ctx.cwd, { hook_event_name: "SessionEnd" }),
    );
    startedSessions.delete(`pi-${rootSessionId}`);
    identityCache.delete(rootSessionId);
    continuedReplies.delete(`pi-${rootSessionId}`);
    activeRootSessionId = null;
  });

  pi.on("session_switch", async (_event, ctx) => {
    await resolveAndEnsureStart(ctx);
  });

  pi.on("input", async (event, ctx) => {
    const text = (event as Record<string, unknown>).text?.toString().trim() ?? "";
    const sessionId = ctx.sessionManager.getSessionId();
    // Only act when the session is already known to CodeIsland — emitting
    // SessionStart for an unseen session would create a phantom card.
    if (!startedSessions.has(`pi-${sessionId}`)) return;
    const identity: OmpSessionIdentity = { kind: "root", sessionId };

    if (text === "/clear") {
      // Retain the card by re-emitting SessionStart for the same root identity.
      // This clears the card's stale content without removing it from the UI.
      // startedSessions and identityCache are intentionally left intact so
      // the next lifecycle event sees the session as already started.
      const sessionName = pi.getSessionName();
      await sendFn(
        buildEvent(identity, ctx.cwd, {
          hook_event_name: "SessionStart",
          ...(sessionName ? { session_title: sessionName } : {}),
        }),
      );
      return;
    }

    if (text.startsWith("/rename ")) {
      // Parse the new name directly from the command text — pi.getSessionName()
      // still holds the old name at input-event time (omp applies /rename after
      // the input event resolves).
      const newName = text.slice("/rename ".length).trim();
      if (!newName) return;
      await sendFn(
        buildEvent(identity, ctx.cwd, {
          hook_event_name: "SessionStart",
          session_title: newName,
        }),
      );
    }
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
    const resolvedEarly = await resolveAndEnsureStart(ctx);
    const sid = resolvedEarly?.sid;
    const reply = extractLastAssistantText(event.messages);

    // OMP goes on with this turn (OMP's own Warp bridge reads the flag the
    // same way): its Stop, and the chime, wait for the run that ends it. An
    // OMP before 17.0.2 sends no flag, and every run ends a turn as before.
    if ((event as Record<string, unknown>).willContinue === true) {
      if (sid && reply) continuedReplies.set(sid, reply);
      return;
    }
    const accumulatedReply = sid ? (reply || continuedReplies.get(sid) || "") : reply;
    if (sid) continuedReplies.delete(sid);

    if (!resolvedEarly) return;
    const { identity } = resolvedEarly;

    if (pendingPermissionSessions.has(resolvedEarly.sid)) return;

    const sessionName = pi.getSessionName();

    await sendFn(
      buildEvent(identity, ctx.cwd, {
        hook_event_name: "Stop",
        last_assistant_message: accumulatedReply || undefined,
        ...(interruptedByUser(event.messages) ? { stop_reason: "interrupted" } : {}),
        ...(identity.kind === "root" && sessionName ? { session_title: sessionName } : {}),
      }),
    );
  });

  // ── Tool calls ─────────────────────────────────────────────────────────────

  pi.on("tool_call", async (event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx, true);
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

      const request = buildEvent(identity, ctx.cwd, {
        hook_event_name: "PermissionRequest",
        tool_name: toolName,
        tool_input: toolInput,
        _pi_tool_call_id: event.toolCallId,
      });

      let response: Record<string, unknown> | null = null;
      try {
        response = await sendAndWaitResponse(request);
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

  pi.on("tool_result", async (event, ctx) => {
    const resolved = await resolveAndEnsureStart(ctx);
    if (!resolved) return;
    const { sid } = resolved;

    if (pendingPermissionSessions.has(sid)) return;

    await sendFn(
      buildEvent(resolved.identity, ctx.cwd, { hook_event_name: "PostToolUse" }),
    );

    // The `todo` tool's result carries the whole post-op checklist in
    // `details.phases`. Forward it as a TodoWrite-shaped PostToolUse so
    // CodeIsland's task-progress bar can read it (its TodoWrite path reads the
    // list from `tool_input`). PostToolUse, not PreToolUse: the tool has already
    // finished, so this must not leave a phantom "running" tool on the card.
    //
    // Root-scoped only: a subagent's todo list belongs to that subagent's work
    // context, not the parent's canonical checklist. HookServer merges subagent
    // PostToolUse events onto the parent card for display, which would overwrite
    // the root session's task-progress bar with child items.
    if (event.toolName === "todo" && resolved.identity.kind === "root") {
      const detailsObj = event.details;
      if (detailsObj && typeof detailsObj === "object" && "phases" in detailsObj) {
        const phases = (detailsObj as Record<"phases", unknown>).phases;
        const snapshot = ompTodoSnapshot(
          Array.isArray(phases) ? (phases as OmpTodoPhase[]) : undefined,
        );
        if (snapshot) {
          await sendFn(
            buildEvent(resolved.identity, ctx.cwd, {
              hook_event_name: "PostToolUse",
              tool_name: "TodoWrite",
              tool_input: snapshot,
            }),
          );
        }
      }
    }
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
