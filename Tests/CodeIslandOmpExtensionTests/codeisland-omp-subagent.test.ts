import { describe, expect, test } from "bun:test";

// The module reads HOME while loading; dynamic import isolates the no-bridge boundary.
const originalHome = process.env.HOME;
process.env.HOME = "/tmp/codeisland-omp-extension-tests-no-bridge";
const {
  default: codeislandExtension,
  resolveOmpIdentity,
} = await import("../../Sources/CodeIsland/Resources/codeisland-omp?subagent-tests");
if (originalHome === undefined) {
  delete process.env.HOME;
} else {
  process.env.HOME = originalHome;
}

interface RegistrySessionManager {
  getSessionId(): string;
}

interface RegistryRef {
  id: string;
  kind: "main" | "sub" | "advisor";
  parentId?: string;
  session: { sessionManager: RegistrySessionManager } | null;
  status?: "running" | "idle" | "parked" | "aborted";
}

type RegistryEventType = "registered" | "status_changed" | "metadata_changed" | "removed";

/** Test registry with a live `onChange` fan-out and an `emit` test seam. */
interface FakeRegistry {
  get: (id: string) => RegistryRef | undefined;
  list: () => RegistryRef[];
  onChange: (listener: (event: { type: RegistryEventType; ref: RegistryRef }) => void) => () => void;
  emit: (type: RegistryEventType, ref: RegistryRef) => void;
}

function registry(refs: RegistryRef[]): FakeRegistry {
  const listeners = new Set<(event: { type: RegistryEventType; ref: RegistryRef }) => void>();
  return {
    get: (id: string) => refs.find((ref) => ref.id === id),
    list: () => refs,
    onChange: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    emit: (type, ref) => {
      for (const listener of listeners) listener({ type, ref });
    },
  };
}

/** Mirrors OmpAgentContext (ctx.agent) without importing it from the dynamic module. */
type AgentCtx = { kind: "main" | "sub"; id: string; name: string; depth: number; parentId?: string };

describe("resolveOmpIdentity", () => {
  test("classifies a main agent as root without consulting the registry", () => {
    const sessionManager = { getSessionId: () => "root-session" };
    expect(resolveOmpIdentity(
      sessionManager,
      registry([]),
      { kind: "main", id: "Main", name: "main", depth: 0 },
    )).toEqual({ kind: "root", sessionId: "root-session" });
  });

  test("routes a subagent to the top-level session using its registry id", () => {
    const rootManager = { getSessionId: () => "root-session" };
    const childManager = { getSessionId: () => "child-session" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "ReviewerA", kind: "sub", parentId: "Main", session: { sessionManager: childManager } },
    ];
    // The agent name comes from ctx.agent, not from session_init entries.
    expect(resolveOmpIdentity(
      childManager,
      registry(refs),
      { kind: "sub", id: "ReviewerA", name: "reviewer", depth: 1, parentId: "Main" },
    )).toEqual({
      kind: "subagent",
      sessionId: "child-session",
      rootSessionId: "root-session",
      agentId: "ReviewerA",
      agentType: "reviewer",
    });
  });

  test("routes a nested subagent to the top-level session", () => {
    const rootManager = { getSessionId: () => "root-session" };
    const parentManager = { getSessionId: () => "parent-session" };
    const childManager = { getSessionId: () => "nested-session" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "ParentScout", kind: "sub", parentId: "Main", session: { sessionManager: parentManager } },
      { id: "ParentScout.ChildReviewer", kind: "sub", parentId: "ParentScout", session: { sessionManager: childManager } },
    ];
    expect(resolveOmpIdentity(
      childManager,
      registry(refs),
      { kind: "sub", id: "ParentScout.ChildReviewer", name: "reviewer", depth: 2, parentId: "ParentScout" },
    )).toEqual({
      kind: "subagent",
      sessionId: "nested-session",
      rootSessionId: "root-session",
      agentId: "ParentScout.ChildReviewer",
      agentType: "reviewer",
    });
  });

  test("leaves a subagent unresolved when its registry lineage is incomplete", () => {
    const childManager = { getSessionId: () => "child-session" };
    expect(resolveOmpIdentity(
      childManager,
      registry([{ id: "ReviewerA", kind: "sub", parentId: "missing", session: { sessionManager: childManager } }]),
      { kind: "sub", id: "ReviewerA", name: "reviewer", depth: 1, parentId: "missing" },
    )).toEqual({ kind: "unresolved" });
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
  registryRefs: RegistryRef[] = [],
): {
  api: Parameters<typeof codeislandExtension>[0];
  handlers: Map<string, (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<void>>;
  tools: Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>;
  registry: FakeRegistry;
} {
  const handlers = new Map<string, (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<void>>();
  const tools = new Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>();
  const agentRegistry = registry(registryRefs);
  const api = {
    zod: {
      string: fakeSchema,
      number: fakeSchema,
      boolean: fakeSchema,
      array: fakeSchema,
      object: fakeSchema,
    },
    pi: {
      AgentRegistry: { global: () => agentRegistry },
      Text: class { constructor(readonly text: string) {} },
      AskTool: class { constructor(_: unknown) {} readonly name = "ask"; readonly label = "Ask"; readonly description = ""; readonly parameters = fakeSchema(); readonly strict = true; readonly approval = "read"; readonly concurrency = "exclusive"; async execute() { return { content: [{ type: "text", text: "User selected: Option A" }], details: { question: "q", options: ["Option A"], multi: false, selectedOptions: ["Option A"] } }; } },
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
  return { api, handlers, tools, registry: agentRegistry };
}

function makeRootCtx(sessionId: string, cwd = "/project"): Record<string, unknown> {
  return {
    cwd,
    hasUI: true,
    agent: { kind: "main", id: "Main", name: "main", depth: 0 } satisfies AgentCtx,
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
  agent: AgentCtx,
  cwd = "/project",
): Record<string, unknown> & { sessionManager: RegistrySessionManager; hasUI: boolean } {
  return {
    cwd,
    hasUI: true,
    agent,
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


  test("session_shutdown emits no SessionEnd after child identity cached by a non-start handler", async () => {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("child-cache-sid", { kind: "sub", id: "Scout", name: "scout", depth: 1, parentId: "Main" });
    const sessionManager = ctx.sessionManager;
    const rootManager = { getSessionId: () => "root-provider-id" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "Scout", kind: "sub", parentId: "Main", session: { sessionManager } },
    ];
    const { handlers } = makeExtensionApi(sent, undefined, refs);

    await handlers.get("agent_end")!({ messages: [] }, ctx);
    const beforeShutdown = sent.length;
    await handlers.get("session_shutdown")!({}, ctx);

    expect(sent.length).toBe(beforeShutdown);
    expect(sent.every((event) => event.hook_event_name !== "SessionEnd")).toBe(true);
  });

  test("unresolved registry lineage does not emit on before_agent_start retry", async () => {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("child-sid", { kind: "sub", id: "Child", name: "task", depth: 1, parentId: "missing" });
    const refs: RegistryRef[] = [
      { id: "Child", kind: "sub", parentId: "missing", session: { sessionManager: ctx.sessionManager } },
    ];
    const { handlers } = makeExtensionApi(sent, undefined, refs);
    const result = await handlers.get("before_agent_start")!({ prompt: "test" }, ctx);

    expect(result).toBeUndefined();
    expect(sent).toHaveLength(0);
  });

  test("unresolved Ask child executes native Ask without any CodeIsland bridge request", async () => {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("child-ask-sid", { kind: "sub", id: "Child", name: "task", depth: 1, parentId: "missing" });
    const refs: RegistryRef[] = [
      { id: "Child", kind: "sub", parentId: "missing", session: { sessionManager: ctx.sessionManager } },
    ];
    const { tools } = makeExtensionApi(sent, undefined, refs);
    const askTool = tools.get("ask");
    expect(askTool).toBeDefined();

    const params = {
      questions: [{
        id: "q1",
        question: "Pick one",
        options: [{ label: "Option A" }],
        multi: false,
      }],
    };
    const result = await askTool!.execute("call-1", params, undefined, () => {}, ctx);

    expect(result).toBeDefined();
    const r = result as { content: { type: string; text: string }[] };
    expect(r.content.length).toBeGreaterThan(0);
    expect(sent).toHaveLength(0);
  });
});

// ── Registry-driven SubagentStop teardown ─────────────────────────────────────

describe("registry-driven SubagentStop", () => {
  // Builds a started subagent: emits SubagentStart, returns the harness plus a
  // handle to fire registry lifecycle events for that child's ref.
  async function startedSubagent(agentId = "Parent.Child") {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("nested-session", { kind: "sub", id: agentId, name: "reviewer", depth: 2, parentId: "Parent" });
    const rootManager = { getSessionId: () => "root-provider-id" };
    const parentManager = { getSessionId: () => "parent-provider-id" };
    const childRef: RegistryRef = { id: agentId, kind: "sub", parentId: "Parent", session: { sessionManager: ctx.sessionManager }, status: "running" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "Parent", kind: "sub", parentId: "Main", session: { sessionManager: parentManager } },
      childRef,
    ];
    const { handlers, registry: reg } = makeExtensionApi(sent, undefined, refs);
    await handlers.get("session_start")!({}, ctx);
    expect(sent.map((e) => e.hook_event_name)).toContain("SubagentStart");
    sent.length = 0;
    return { sent, reg, childRef, agentId };
  }

  test("parked status emits SubagentStop routed to the parent", async () => {
    const { sent, reg, childRef, agentId } = await startedSubagent();
    childRef.status = "parked";
    reg.emit("status_changed", childRef);
    await Promise.resolve();

    const stops = sent.filter((e) => e.hook_event_name === "SubagentStop");
    expect(stops).toHaveLength(1);
    expect(stops[0]!._omp_subagent).toBe(true);
    expect(stops[0]!._omp_agent_id).toBe(agentId);
    expect(stops[0]!._omp_parent_session_id).toBe("pi-root-provider-id");
  });

  test("aborted status emits SubagentStop", async () => {
    const { sent, reg, childRef } = await startedSubagent();
    childRef.status = "aborted";
    reg.emit("status_changed", childRef);
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(1);
  });

  test("removed emits SubagentStop", async () => {
    const { sent, reg, childRef } = await startedSubagent();
    reg.emit("removed", childRef);
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(1);
  });

  test("idle status does NOT emit SubagentStop (live, revivable child keeps its card)", async () => {
    const { sent, reg, childRef } = await startedSubagent();
    childRef.status = "idle";
    reg.emit("status_changed", childRef);
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(0);
  });

  test("a settle for a main/root ref never emits SubagentStop", async () => {
    const { sent, reg } = await startedSubagent();
    reg.emit("removed", { id: "Main", kind: "main", session: null, status: "parked" });
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(0);
  });

  test("removed then parked emits SubagentStop only once (idempotent teardown)", async () => {
    const { sent, reg, childRef } = await startedSubagent();
    reg.emit("removed", childRef);
    childRef.status = "parked";
    reg.emit("status_changed", childRef);
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(1);
  });

  test("a settle for an unknown (never-started) subagent id emits nothing", async () => {
    const { sent, reg } = await startedSubagent();
    reg.emit("removed", { id: "Ghost.Unknown", kind: "sub", parentId: "Parent", session: null, status: "parked" });
    await Promise.resolve();

    expect(sent.filter((e) => e.hook_event_name === "SubagentStop")).toHaveLength(0);
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

  test("nested child session_start emits the top-level parent ID", async () => {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("nested-session", { kind: "sub", id: "Parent.Child", name: "reviewer", depth: 2, parentId: "Parent" });
    const childManager = ctx.sessionManager;
    const rootManager = { getSessionId: () => "root-provider-id" };
    const parentManager = { getSessionId: () => "parent-provider-id" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "Parent", kind: "sub", parentId: "Main", session: { sessionManager: parentManager } },
      { id: "Parent.Child", kind: "sub", parentId: "Parent", session: { sessionManager: childManager } },
    ];
    const { handlers } = makeExtensionApi(sent, undefined, refs);
    await handlers.get("session_start")!({}, ctx);

    expect(sent).toHaveLength(1);
    expect(sent[0]!.hook_event_name).toBe("SubagentStart");
    expect(sent[0]!._omp_subagent).toBe(true);
    expect(sent[0]!._omp_parent_session_id).toBe("pi-root-provider-id");
    expect(sent[0]!._omp_agent_id).toBe("Parent.Child");
    expect(sent[0]!._omp_agent_type).toBe("reviewer");
  });

  test("child session_shutdown emits no SessionEnd", async () => {
    const sent: Record<string, unknown>[] = [];
    const ctx = makeChildCtx("child-session", { kind: "sub", id: "Child", name: "scout", depth: 1, parentId: "Main" });
    const childManager = ctx.sessionManager;
    const rootManager = { getSessionId: () => "root-provider-id" };
    const refs: RegistryRef[] = [
      { id: "Main", kind: "main", session: { sessionManager: rootManager } },
      { id: "Child", kind: "sub", parentId: "Main", session: { sessionManager: childManager } },
    ];
    const { handlers } = makeExtensionApi(sent, undefined, refs);

    await handlers.get("session_start")!({}, ctx);
    const beforeShutdown = sent.length;
    await handlers.get("session_shutdown")!({}, ctx);

    expect(sent.length).toBe(beforeShutdown);
    expect(sent.every((event) => event.hook_event_name !== "SessionEnd")).toBe(true);
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

  // ── root session identity handoff ───────────────────────────────────────────

  test("session_switch ends pi-old-root and immediately starts pi-new-root", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);

    await handlers.get("session_start")!({}, makeRootCtx("old-root"));
    sent.length = 0;
    await handlers.get("session_switch")!({ reason: "new" }, makeRootCtx("new-root"));

    expect(sent.map((event) => [event.hook_event_name, event.session_id])).toEqual([
      ["SessionEnd", "pi-old-root"],
      ["SessionStart", "pi-new-root"],
    ]);
  });

  test("session_switch followed by session_start does not duplicate SessionStart", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const newCtx = makeRootCtx("new-root");

    await handlers.get("session_start")!({}, makeRootCtx("old-root"));
    await handlers.get("session_switch")!({ reason: "new" }, newCtx);
    sent.length = 0;
    await handlers.get("session_start")!({}, newCtx);

    expect(sent).toHaveLength(0);
  });


  test("session_switch handles every reason as a root identity handoff", async () => {
    for (const reason of ["resume", "fork", "fresh", "future-command"]) {
      const sent: Record<string, unknown>[] = [];
      const { handlers } = makeExtensionApi(sent);
      await handlers.get("session_start")!({}, makeRootCtx(`${reason}-old`));
      sent.length = 0;

      await handlers.get("session_switch")!({ reason }, makeRootCtx(`${reason}-new`));

      expect(sent.map((event) => [event.hook_event_name, event.session_id])).toEqual([
        ["SessionEnd", `pi-${reason}-old`],
        ["SessionStart", `pi-${reason}-new`],
      ]);
    }
  });

  test("session_start heals a root identity change without session_switch", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);

    await handlers.get("session_start")!({}, makeRootCtx("temporary-root"));
    sent.length = 0;
    await handlers.get("session_start")!({}, makeRootCtx("persisted-root"));

    expect(sent.map((event) => [event.hook_event_name, event.session_id])).toEqual([
      ["SessionEnd", "pi-temporary-root"],
      ["SessionStart", "pi-persisted-root"],
    ]);
  });

  test("session_switch with an unchanged root ID emits nothing", async () => {
    const sent: Record<string, unknown>[] = [];
    const { handlers } = makeExtensionApi(sent);
    const ctx = makeRootCtx("stable-root");

    await handlers.get("session_start")!({}, ctx);
    sent.length = 0;
    await handlers.get("session_switch")!({ reason: "fresh" }, ctx);

    expect(sent).toHaveLength(0);
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
