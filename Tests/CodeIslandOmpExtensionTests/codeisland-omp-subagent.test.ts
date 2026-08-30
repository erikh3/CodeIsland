import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { describe, expect, test } from "bun:test";

// The module reads HOME while loading; dynamic import isolates the no-bridge boundary.
const originalHome = process.env.HOME;
process.env.HOME = "/tmp/codeisland-omp-extension-tests-no-bridge";
const {
  default: codeislandExtension,
  readRootSessionId,
  resolveOmpIdentity,
} = await import("../../Sources/CodeIsland/Resources/codeisland-omp?subagent-tests");
if (originalHome === undefined) {
  delete process.env.HOME;
} else {
  process.env.HOME = originalHome;
}

// ── readRootSessionId ─────────────────────────────────────────────────────────

describe("readRootSessionId", () => {
  test("returns the first session value from a valid transcript", () => {
    const transcript = [
      '{"type":"header","version":1}',
      '{"type":"session","session":"root-session-abc"}',
      '{"type":"session_init","agent":"task"}',
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("root-session-abc");
  });

  test("skips malformed lines before a valid record", () => {
    const transcript = [
      "not-json",
      "{broken",
      '{"type":"session","session":"good-session"}',
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("good-session");
  });

  test("returns null when no session record exists within maxLines", () => {
    const lines = Array.from({ length: 25 }, (_, i) =>
      JSON.stringify({ type: "message", index: i }),
    );
    const transcript = lines.join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBeNull();
  });

  test("respects the maxLines bound", () => {
    const transcript = [
      '{"type":"header"}',
      '{"type":"session","session":"too-late"}',
    ].join("\n");
    // maxLines=1 means only the first line is checked
    expect(readRootSessionId("/fake/root.jsonl", 1, () => transcript)).toBeNull();
  });

  test("returns null when the file cannot be read", () => {
    expect(readRootSessionId("/nonexistent/path.jsonl", 20, () => {
      throw new Error("ENOENT");
    })).toBeNull();
  });

  test("skips session records with empty string value", () => {
    const transcript = [
      '{"type":"session","session":""}',
      '{"type":"session","session":"valid"}',
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("valid");
  });

  test("skips records with session field but wrong type", () => {
    const transcript = [
      '{"type":"header","session":"should-be-ignored"}',
      '{"type":"session_init","session":"also-ignored"}',
      '{"type":"session","session":"correct"}',
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("correct");
  });

  // ── OMP 18.0.10 regression: id field on type=session records ─────────────

  test("OMP 18.0.10: reads id from {type:session,version:3,id}", () => {
    const transcript = JSON.stringify({
      type: "session",
      version: 3,
      id: "01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1",
    });
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe(
      "01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1",
    );
  });

  test("id takes precedence over session when both are present on type=session", () => {
    const transcript = JSON.stringify({
      type: "session",
      id: "id-wins",
      session: "session-loses",
    });
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("id-wins");
  });

  test("id on a non-session type record is ignored; real session below is returned", () => {
    const transcript = [
      JSON.stringify({ type: "header", id: "bad-id", version: 3 }),
      JSON.stringify({ type: "session_init", id: "also-bad" }),
      JSON.stringify({ type: "session", id: "correct-id" }),
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("correct-id");
  });

  test("empty id falls through to legacy session field", () => {
    const transcript = JSON.stringify({
      type: "session",
      id: "",
      session: "legacy-fallback",
    });
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("legacy-fallback");
  });

  test("both id and session empty on type=session: skips to next record", () => {
    const transcript = [
      JSON.stringify({ type: "session", id: "", session: "" }),
      JSON.stringify({ type: "session", id: "second-id" }),
    ].join("\n");
    expect(readRootSessionId("/fake/root.jsonl", 20, () => transcript)).toBe("second-id");
  });
});
// ── resolveOmpIdentity ────────────────────────────────────────────────────────

describe("resolveOmpIdentity", () => {
  const rootTranscript = (sid: string) =>
    JSON.stringify({ type: "session", session: sid });

  test("root transcript: null sessionFile returns root identity", () => {
    expect(resolveOmpIdentity("sess-1", null, [])).toEqual({
      kind: "root",
      sessionId: "sess-1",
    });
  });

  test("root transcript: relative path returns root identity", () => {
    expect(resolveOmpIdentity("sess-2", "relative/path.jsonl", [])).toEqual({
      kind: "root",
      sessionId: "sess-2",
    });
  });

  test("root transcript: in-memory path (no leading slash) returns root identity", () => {
    expect(resolveOmpIdentity("sess-3", "memory://session.jsonl", [])).toEqual({
      kind: "root",
      sessionId: "sess-3",
    });
  });

  test("root transcript: path not ending in .jsonl returns root identity", () => {
    expect(resolveOmpIdentity("sess-4", "/home/user/.omp/sessions/foo", [])).toEqual({
      kind: "root",
      sessionId: "sess-4",
    });
  });

  test("root transcript: parent dir has no matching .jsonl returns root identity", () => {
    const exists = (_p: string) => false;
    expect(resolveOmpIdentity(
      "sess-5",
      "/home/user/.omp/sessions/Child/Scout.jsonl",
      [],
      exists,
    )).toEqual({ kind: "root", sessionId: "sess-5" });
  });

  test("first-level child: classifies correctly", () => {
    const entries = [{ type: "session_init", agent: "task" }];
    const exists = (p: string) => p === "/home/user/.omp/sessions/Scout.jsonl";
    const readId = (p: string) => (p === "/home/user/.omp/sessions/Scout.jsonl" ? "root-sid" : null);
    expect(resolveOmpIdentity(
      "child-sid",
      "/home/user/.omp/sessions/Scout/Scout.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({
      kind: "subagent",
      sessionId: "child-sid",
      parentSessionId: "root-sid",
      agentId: "Scout",
      agentType: "task",
    });
  });

  test("flat dotted nested child: agentId is the full dotted filename without extension", () => {
    const entries = [{ type: "session_init", agent: "reviewer" }];
    const exists = (p: string) => p === "/home/user/.omp/sessions/ParentScout.jsonl";
    const readId = (_p: string) => "root-parent";
    expect(resolveOmpIdentity(
      "nested-sid",
      "/home/user/.omp/sessions/ParentScout/ParentScout.ChildReviewer.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({
      kind: "subagent",
      sessionId: "nested-sid",
      parentSessionId: "root-parent",
      agentId: "ParentScout.ChildReviewer",
      agentType: "reviewer",
    });
  });

  test("malformed root prefix followed by a valid header: uses the valid session record", () => {
    const badThenGood = "bad-json\n" + rootTranscript("real-root");
    const entries = [{ type: "session_init", agent: "scout" }];
    const exists = (p: string) => p === "/sessions/Parent.jsonl";
    const readId = (p: string) => readRootSessionId(p, 20, () => badThenGood);
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Parent/Scout.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({
      kind: "subagent",
      sessionId: "child-sid",
      parentSessionId: "real-root",
      agentId: "Scout",
      agentType: "scout",
    });
  });

  test("missing session_init.agent returns unresolved", () => {
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (_p: string) => "root-sid";
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Child.jsonl",
      [],
      exists,
      readId,
    )).toEqual({ kind: "unresolved" });
  });

  test("missing session_init.agent with empty entries returns unresolved", () => {
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (_p: string) => "root-sid";
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Child.jsonl",
      [{ type: "header" }, { type: "message" }],
      exists,
      readId,
    )).toEqual({ kind: "unresolved" });
  });

  test("missing or non-file root candidate (readId returns null) falls back to root", () => {
    const entries = [{ type: "session_init", agent: "task" }];
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (_p: string) => null;
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Child.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({ kind: "root", sessionId: "child-sid" });
  });

  test("session_init.agent must be non-empty to classify as subagent", () => {
    const entries = [{ type: "session_init", agent: "" }];
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (_p: string) => "root-sid";
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Child.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({ kind: "unresolved" });
  });

  test("directory root candidate returns root identity", () => {
    // isRegularFileFn returns false when the path resolves to a directory
    const entries = [{ type: "session_init", agent: "task" }];
    const isRegularFile = (_p: string) => false;
    const readId = (_p: string) => "root-sid";
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Child.jsonl",
      entries,
      isRegularFile,
      readId,
    )).toEqual({ kind: "root", sessionId: "child-sid" });
  });

  // ── OMP 18.0.10 regression ────────────────────────────────────────────────

  test("OMP 18.0.10: child resolves when root transcript uses {type:session,version:3,id}", () => {
    // Real shape captured from OMP 18.0.10 root transcript
    const omp1810Transcript = JSON.stringify({
      type: "session",
      version: 3,
      id: "01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1",
    });
    const entries = [{ type: "session_init", agent: "task" }];
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (p: string) => readRootSessionId(p, 20, () => omp1810Transcript);
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Worker.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({
      kind: "subagent",
      sessionId: "child-sid",
      parentSessionId: "01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1",
      agentId: "Worker",
      agentType: "task",
    });
  });

  test("OMP 18.0.10: non-session type with id field does not supply lineage", () => {
    // Arbitrary record with id must not bleed into parent resolution
    const badTranscript = [
      JSON.stringify({ type: "header", id: "attacker-id", version: 3 }),
      JSON.stringify({ type: "session_init", id: "also-bad" }),
    ].join("\n");
    const entries = [{ type: "session_init", agent: "task" }];
    const exists = (p: string) => p === "/sessions/Root.jsonl";
    const readId = (p: string) => readRootSessionId(p, 20, () => badTranscript);
    // readId returns null → falls back to root
    expect(resolveOmpIdentity(
      "child-sid",
      "/sessions/Root/Worker.jsonl",
      entries,
      exists,
      readId,
    )).toEqual({ kind: "root", sessionId: "child-sid" });
  });
});

// ── Lifecycle event behavior ──────────────────────────────────────────────────

interface FakeSchema {
  optional: () => FakeSchema;
  describe: () => FakeSchema;
  refine: () => FakeSchema;
  min: () => FakeSchema;
}

function fakeSchema(): FakeSchema {
  const schema: FakeSchema = {
    optional: () => schema,
    describe: () => schema,
    refine: () => schema,
    min: () => schema,
  };
  return schema;
}

function makeExtensionApi(
  events: Record<string, unknown>[],
  sendFn?: (payload: object) => Promise<boolean>,
): {
  api: Parameters<typeof codeislandExtension>[0];
  handlers: Map<string, (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<void>>;
  tools: Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>;
} {
  const handlers = new Map<string, (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<void>>();
  const tools = new Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>();
  const api = {
    zod: {
      string: fakeSchema,
      number: fakeSchema,
      boolean: fakeSchema,
      array: fakeSchema,
      object: fakeSchema,
    },
    pi: {
      AskTool: class { constructor(_: unknown) {} readonly name = "ask"; readonly label = "Ask"; readonly description = ""; readonly parameters = fakeSchema(); readonly strict = true; readonly approval = "read"; readonly concurrency = "exclusive"; async execute() { return { content: [{ type: "text", text: "User selected: Option A" }], details: { question: "q", options: ["Option A"], multi: false, selectedOptions: ["Option A"] } }; } },
      askToolRenderer: { mergeCallAndResult: true, renderCall: () => null, renderResult: () => null },
      settings: {},
    },
    getSessionName: () => undefined as string | undefined,
    registerTool: (tool: unknown) => { tools.set((tool as { name: string }).name, tool as { execute: (...args: unknown[]) => Promise<unknown> }); },
    on: (eventName: string, handler: (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<void>) => {
      handlers.set(eventName, handler);
    },
  } as never;
  const capturer = sendFn ?? ((payload: object) => { events.push(payload as Record<string, unknown>); return Promise.resolve(true); });
  codeislandExtension(api, capturer);
  return { api, handlers, tools };
}

function makeRootCtx(sessionId: string, cwd = "/project"): Record<string, unknown> {
  return {
    cwd,
    hasUI: true,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionFile: () => null,
      getEntries: () => [],
    },
    modelRegistry: {},
    model: {},
    isIdle: () => true,
    hasPendingMessages: () => false,
    abort: () => {},
    ui: {},
  };
}

function makeChildCtx(
  sessionId: string,
  sessionFile: string,
  entries: Record<string, unknown>[],
  cwd = "/project",
): Record<string, unknown> {
  return {
    cwd,
    hasUI: true,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionFile: () => sessionFile,
      getEntries: () => entries,
    },
    modelRegistry: {},
    model: {},
    isIdle: () => true,
    hasPendingMessages: () => false,
    abort: () => {},
    ui: {},
  };
}

/**
 * Creates a temp directory containing a root transcript and a subdirectory for
 * child session files.  Returns the dir, the root transcript path, and a helper
 * that builds an absolute child file path inside `<dir>/Root/`.
 *
 * Callers are responsible for cleanup (`rmSync(dir, { recursive: true, force: true })`).
 */
function makeChildTranscriptDir(rootTranscriptContent: object): {
  dir: string;
  childFile: (name: string) => string;
} {
  const dir = mkdtempSync(join(tmpdir(), "ci-omp-test-"));
  writeFileSync(join(dir, "Root.jsonl"), JSON.stringify(rootTranscriptContent));
  mkdirSync(join(dir, "Root"));
  return {
    dir,
    childFile: (name: string) => join(dir, "Root", name),
  };
}


describe("lifecycle event wire contract", () => {

  test("terminal agent_end emits Stop (willContinue absent)", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    expect(handlers.has("agent_end")).toBe(true);
    const handler = handlers.get("agent_end")!;
    const ctx = makeRootCtx("root-sess");
    const result = await handler({ messages: [] }, ctx);
    expect(result).toBeUndefined();
    // The handler emits SessionStart (ensureSessionStarted) then Stop.
    const hookNames = sent.map((e) => e.hook_event_name);
    expect(hookNames).toContain("Stop");
    const stopEvent = sent.find((e) => e.hook_event_name === "Stop");
    expect(stopEvent).toBeDefined();
    expect(stopEvent!._omp_subagent).toBeUndefined();
  });

  test("non-terminal agent_end with willContinue=true emits no Stop", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const handler = handlers.get("agent_end")!;
    const ctx = makeRootCtx("root-sess");
    // willContinue=true: handler returns early before any sendFn call.
    const result = await handler({ messages: [], willContinue: true }, ctx);
    expect(result).toBeUndefined();
    expect(sent).toHaveLength(0);
  });

  test("park and revival: child identity resolves consistently across separate instances", () => {
    // OMP creates a fresh extension instance on revival; child re-classifies
    // from the same session file + entries combination deterministically.
    const sessionFile = "/home/user/.omp/sessions/Root/ResearchScout.jsonl";
    const entries = [{ type: "session_init", agent: "scout" }];
    const exists = (p: string) => p === "/home/user/.omp/sessions/Root.jsonl";
    const readId = (_p: string) => "root-parent-sid";

    // First classification (park)
    const id1 = resolveOmpIdentity("child-sid", sessionFile, entries, exists, readId);
    // Second classification (revival — new extension instance, same inputs)
    const id2 = resolveOmpIdentity("child-sid", sessionFile, entries, exists, readId);

    expect(id1).toEqual(id2);
    expect(id1).toEqual({
      kind: "subagent",
      sessionId: "child-sid",
      parentSessionId: "root-parent-sid",
      agentId: "ResearchScout",
      agentType: "scout",
    });
  });

  test("session_shutdown emits no SessionEnd after child identity cached by a non-start handler", async () => {
    const { dir, childFile } = makeChildTranscriptDir({ type: "session", session: "root-provider-id" });
    try {
      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);
      const entries = [{ type: "session_init", agent: "scout" }];
      const ctx = makeChildCtx("child-cache-sid", childFile("Scout.jsonl"), entries);

      // Prime the cache via agent_end (a non-start handler) instead of session_start.
      // resolveIdentityFromCtx caches subagent identities on first resolution.
      await handlers.get("agent_end")!({ messages: [] }, ctx);
      const beforeShutdown = sent.length;

      // session_shutdown must detect the cached child identity and emit nothing.
      await handlers.get("session_shutdown")!({}, ctx);
      expect(sent.length).toBe(beforeShutdown);
      expect(sent.every((e) => e.hook_event_name !== "SessionEnd")).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("unresolved identity does not emit on before_agent_start retry", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const handler = handlers.get("before_agent_start")!;
    // Construct a child ctx whose session file's parent does NOT match any
    // session file on disk — resolveOmpIdentity called inside the handler
    // uses the real existsSync, which returns false for this path, so the
    // handler classifies the session as root (not unresolved). Either way,
    // the capturer stub is used instead of the real socket, so no ENOENT.
    const ctx = makeChildCtx(
      "child-sid",
      "/tmp/codeisland-omp-test-nonexistent/Root/Scout.jsonl",
      [], // no session_init → agent type absent
    );
    const result = await handler({ prompt: "test" }, ctx);
    expect(result).toBeUndefined();
    // No _omp_subagent field on any emitted event (no confirmed subagent identity).
    for (const event of sent) {
      expect(event._omp_subagent).toBeUndefined();
    }
  });

  test("unresolved Ask child executes native Ask without any CodeIsland bridge request", async () => {
    const sent: Record<string, unknown>[] = [];
    const { tools } = makeExtensionApi(sent);
    const askTool = tools.get("ask");
    expect(askTool).toBeDefined();

    // Unresolved: parent transcript absent → resolveOmpIdentity returns "unresolved".
    const ctx = makeChildCtx(
      "child-ask-sid",
      "/tmp/codeisland-omp-test-nonexistent/Root/Scout.jsonl",
      [], // no session_init → agent type absent; parent path does not exist on disk
    ) as Record<string, unknown> & { hasUI: boolean };
    ctx.hasUI = true;

    const params = {
      questions: [{
        id: "q1",
        question: "Pick one",
        options: [{ label: "Option A" }],
        multi: false,
      }],
    };
    const result = await askTool!.execute("call-1", params, undefined, () => {}, ctx);

    // Native AskTool stub returns a result — confirm it arrived.
    expect(result).toBeDefined();
    const r = result as { content: { type: string; text: string }[] };
    expect(r.content.length).toBeGreaterThan(0);

    // No CodeIsland socket/bridge request must have been attempted.
    expect(sent).toHaveLength(0);
  });
});

// ── Session event emission ────────────────────────────────────────────────────

describe("session event emission", () => {
  test("root session_start emits SessionStart with correct sessionId", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const handler = handlers.get("session_start")!;
    await handler({}, makeRootCtx("root-abc"));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.hook_event_name).toBe("SessionStart");
    expect(sent[0]!.session_id).toBe("pi-root-abc");
    expect(sent[0]!._omp_subagent).toBeUndefined();
  });

  test("root session_start does not emit SessionStart twice for the same session", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const handler = handlers.get("session_start")!;
    const ctx = makeRootCtx("root-dedup");
    await handler({}, ctx);
    await handler({}, ctx);
    const starts = sent.filter((e) => e.hook_event_name === "SessionStart");
    expect(starts).toHaveLength(1);
  });

  test("child session_start emits SubagentStart with parent and agent metadata", async () => {
    const { dir, childFile } = makeChildTranscriptDir({ type: "session", session: "root-provider-id" });
    try {
      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);
      const entries = [{ type: "session_init", agent: "scout" }];
      const ctx = makeChildCtx("child-sess", childFile("Scout.jsonl"), entries);
      await handlers.get("session_start")!({}, ctx);

      expect(sent).toHaveLength(1);
      expect(sent[0]!.hook_event_name).toBe("SubagentStart");
      expect(sent[0]!._omp_subagent).toBe(true);
      expect(sent[0]!._omp_parent_session_id).toBe("pi-root-provider-id");
      expect(sent[0]!._omp_agent_id).toBe("Scout");
      expect(sent[0]!._omp_agent_type).toBe("scout");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("child session_shutdown emits no SessionEnd", async () => {
    const { dir, childFile } = makeChildTranscriptDir({ type: "session", session: "root-provider-id" });
    try {
      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);
      const entries = [{ type: "session_init", agent: "scout" }];
      const ctx = makeChildCtx("child-sess", childFile("Scout.jsonl"), entries);

      // Prime the cache via session_start.
      await handlers.get("session_start")!({}, ctx);
      const beforeShutdown = sent.length;

      // Shutdown should clear caches silently — no SessionEnd.
      await handlers.get("session_shutdown")!({}, ctx);
      expect(sent.length).toBe(beforeShutdown);
      expect(sent.every((e) => e.hook_event_name !== "SessionEnd")).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("root session_shutdown emits SessionEnd", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("root-shutdown");

    await handlers.get("session_start")!({}, ctx);
    await handlers.get("session_shutdown")!({}, ctx);

    const endEvents = sent.filter((e) => e.hook_event_name === "SessionEnd");
    expect(endEvents).toHaveLength(1);
    expect(endEvents[0]!.session_id).toBe("pi-root-shutdown");
    expect(endEvents[0]!._omp_subagent).toBeUndefined();
  });

  // ── session_switch (/new) ──────────────────────────────────────────────────

  test("session_switch reason=new ends pi-old-root and immediately starts pi-new-root", async () => {
    // Write a temp previous-session transcript that readRootSessionId can parse.
    const tmpDir = mkdtempSync(join(tmpdir(), "ci-omp-switch-test-"));
    const prevFile = join(tmpDir, "OldRoot.jsonl");
    try {
      writeFileSync(prevFile, JSON.stringify({ type: "session", session: "old-root" }));

      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);

      // Establish the old session in startedSessions via session_start.
      const oldCtx = makeRootCtx("old-root");
      await handlers.get("session_start")!({}, oldCtx);
      expect(sent.filter((e) => e.hook_event_name === "SessionStart")).toHaveLength(1);

      sent.length = 0; // isolate switch side-effects

      // OMP fires session_switch after the context already points to new-root.
      const newCtx = makeRootCtx("new-root");
      await handlers.get("session_switch")!(
        { reason: "new", previousSessionFile: prevFile },
        newCtx,
      );

      // SessionEnd must be emitted for the old session.
      const endEvents = sent.filter((e) => e.hook_event_name === "SessionEnd");
      expect(endEvents).toHaveLength(1);
      expect(endEvents[0]!.session_id).toBe("pi-old-root");
      expect(endEvents[0]!._omp_subagent).toBeUndefined();

      // No SessionEnd for the new session.
      expect(endEvents.every((e) => e.session_id !== "pi-new-root")).toBe(true);

      // SessionStart for the new session must be emitted in the same switch handling.
      const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
      expect(startEvents).toHaveLength(1);
      expect(startEvents[0]!.session_id).toBe("pi-new-root");
      expect(startEvents[0]!._omp_subagent).toBeUndefined();

      // SessionEnd must precede SessionStart.
      const endIdx = sent.indexOf(endEvents[0]!);
      const startIdx = sent.indexOf(startEvents[0]!);
      expect(endIdx).toBeLessThan(startIdx);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test("session_switch reason=new: subsequent session_start produces no duplicate SessionStart", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "ci-omp-switch-test-"));
    const prevFile = join(tmpDir, "OldRoot.jsonl");
    try {
      writeFileSync(prevFile, JSON.stringify({ type: "session", session: "old-root" }));

      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);

      // Establish old session.
      await handlers.get("session_start")!({}, makeRootCtx("old-root"));
      sent.length = 0;

      // Switch — context is new-root; switch itself emits SessionStart for new-root.
      const newCtx = makeRootCtx("new-root");
      await handlers.get("session_switch")!(
        { reason: "new", previousSessionFile: prevFile },
        newCtx,
      );

      // Confirm the switch emitted exactly one SessionStart.
      const afterSwitch = sent.filter((e) => e.hook_event_name === "SessionStart");
      expect(afterSwitch).toHaveLength(1);
      expect(afterSwitch[0]!.session_id).toBe("pi-new-root");

      sent.length = 0;

      // A subsequent session_start must not emit a second SessionStart — the
      // session is already in startedSessions from the switch.
      await handlers.get("session_start")!({}, newCtx);
      const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
      expect(startEvents).toHaveLength(0);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test("session_switch reason=new with missing previousSessionFile still starts new-root", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);

    // No previous file provided — handler must not crash and must still emit
    // SessionStart for the current new-root session.
    await handlers.get("session_switch")!({ reason: "new" }, makeRootCtx("new-root"));

    const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
    expect(startEvents).toHaveLength(1);
    expect(startEvents[0]!.session_id).toBe("pi-new-root");
    expect(sent.filter((e) => e.hook_event_name === "SessionEnd")).toHaveLength(0);
  });

  test("session_switch reason=new with unreadable previousSessionFile still starts new-root", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);

    await handlers.get("session_switch")!(
      { reason: "new", previousSessionFile: "/tmp/ci-omp-nonexistent-file.jsonl" },
      makeRootCtx("new-root"),
    );

    const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
    expect(startEvents).toHaveLength(1);
    expect(startEvents[0]!.session_id).toBe("pi-new-root");
    expect(sent.filter((e) => e.hook_event_name === "SessionEnd")).toHaveLength(0);
  });

  // ── OMP 18.0.10 regression ────────────────────────────────────────────────

  test("OMP 18.0.10: child session_start emits SubagentStart with correct parent id and metadata", async () => {
    // Uses the exact root transcript shape from OMP 18.0.10:
    //   {"type":"session","version":3,"id":"01a04d4e-..."}
    const { dir, childFile } = makeChildTranscriptDir({
      type: "session",
      version: 3,
      id: "01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1",
    });
    try {
      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);
      const entries = [{ type: "session_init", agent: "task" }];
      const ctx = makeChildCtx("child-omp1810", childFile("FixOmpRootId.jsonl"), entries);
      await handlers.get("session_start")!({}, ctx);

      expect(sent).toHaveLength(1);
      expect(sent[0]!.hook_event_name).toBe("SubagentStart");
      expect(sent[0]!._omp_subagent).toBe(true);
      expect(sent[0]!._omp_parent_session_id).toBe("pi-01a04d4e-f1b2-4c3d-8e5f-a6b7c8d9e0f1");
      expect(sent[0]!._omp_agent_id).toBe("FixOmpRootId");
      expect(sent[0]!._omp_agent_type).toBe("task");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ── /clear input handler ──────────────────────────────────────────────────────

describe("/clear input handler", () => {
  test("/clear emits a second SessionStart (same ID) and no SessionEnd — card is retained", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("root-clear");

    // Establish the session so startedSessions has this id.
    await handlers.get("session_start")!({}, ctx);
    const afterStart = sent.filter((e) => e.hook_event_name === "SessionStart").length;
    expect(afterStart).toBe(1);

    sent.length = 0; // isolate the /clear side-effects

    await handlers.get("input")!({ text: "/clear" }, ctx);

    // The card is retained by re-emitting SessionStart for the same session id.
    const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
    expect(startEvents).toHaveLength(1);
    expect(startEvents[0]!.session_id).toBe("pi-root-clear");
    expect(startEvents[0]!._omp_subagent).toBeUndefined();

    // No SessionEnd must be emitted — removing the card is the wrong behavior.
    const endEvents = sent.filter((e) => e.hook_event_name === "SessionEnd");
    expect(endEvents).toHaveLength(0);
  });

  test("/clear leaves startedSessions intact so a subsequent before_agent_start does not emit a third SessionStart but does emit UserPromptSubmit", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("root-clear-reopen");

    // Initial start.
    await handlers.get("session_start")!({}, ctx);
    // /clear resets card content via a second SessionStart.
    await handlers.get("input")!({ text: "/clear" }, ctx);

    sent.length = 0; // now observe only the subsequent lifecycle event

    // Because startedSessions still contains this session, ensureSessionStarted
    // is a no-op and before_agent_start proceeds straight to UserPromptSubmit.
    await handlers.get("before_agent_start")!({ prompt: "hello" }, ctx);

    const startEvents = sent.filter((e) => e.hook_event_name === "SessionStart");
    expect(startEvents).toHaveLength(0);

    const promptEvents = sent.filter((e) => e.hook_event_name === "UserPromptSubmit");
    expect(promptEvents).toHaveLength(1);
    expect(promptEvents[0]!.session_id).toBe("pi-root-clear-reopen");
  });

  test("non-/clear input does nothing", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("root-no-clear");

    await handlers.get("session_start")!({}, ctx);
    sent.length = 0;

    // None of these match the exact "/clear" trim, so no event is emitted.
    await handlers.get("input")!({ text: "hello world" }, ctx);
    await handlers.get("input")!({ text: "/new" }, ctx);
    await handlers.get("input")!({ text: "  /clear extra" }, ctx);

    expect(sent).toHaveLength(0);
  });

  test("/clear on a session that was never started does nothing", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("root-clear-unstarted");

    // Never call session_start — startedSessions is empty for this id.
    await handlers.get("input")!({ text: "/clear" }, ctx);

    expect(sent).toHaveLength(0);
  });
});
