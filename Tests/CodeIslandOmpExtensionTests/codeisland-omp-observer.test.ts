import { afterEach, describe, expect, test } from "bun:test";
import codeislandExtension from "../../Sources/CodeIsland/Resources/codeisland-omp";

interface Ref {
	id: string;
	kind: "main" | "sub" | "advisor";
	parentId?: string;
	displayName?: string;
	status: "running" | "idle" | "parked" | "aborted";
	session: ReturnType<typeof session> | null;
}

function session(id: string) {
	const listeners = new Set<(event: Record<string, unknown>) => void>();
  const advisors: { name: string; status: string; yielded: boolean; backlog: number; isPaused: boolean }[] = [];
	return {
		sessionManager: { getSessionId: () => id, getCwd: () => "/repo" },
		model: { id: "child-model", provider: "test" },
		thinkingLevel: "high",
    advisors,
    getAdvisorStatusOverview: () => ({ advisors }),
    getAdvisorStats: () => ({ advisors: advisors.map(advisor => ({ ...advisor, sessionId: `${id}-advisor-${advisor.name}`, model: { provider: "test", id: "advisor-model" } })) }),
		subscribe(listener: (event: Record<string, unknown>) => void) {
			listeners.add(listener);
			return () => listeners.delete(listener);
		},
		emit(event: Record<string, unknown>) {
			for (const listener of listeners) listener(event);
		},
		listenerCount: () => listeners.size
	};
}

const cleanups: (() => Promise<unknown>)[] = [];
afterEach(async () => {
	for (const cleanup of cleanups.splice(0)) await cleanup();
});

function harness() {
	const sent: Record<string, unknown>[] = [];
	const handlers = new Map<string, (event: Record<string, unknown>, ctx: unknown) => Promise<unknown>>();
	const channels = new Map<string, Set<(event: unknown) => void>>();
	const registryListeners = new Set<(event: { type: string; ref: Ref }) => void>();
	const root = session("observer-root");
	const refs = new Map<string, Ref>([["Main", { id: "Main", kind: "main", status: "running", session: root }]]);
	const registry = {
		get: (id: string) => refs.get(id),
		list: () => [...refs.values()],
		onChange(listener: (event: { type: string; ref: Ref }) => void) {
			registryListeners.add(listener);
			return () => registryListeners.delete(listener);
		}
	};
	const schema = { optional: () => schema, describe: () => schema, refine: () => schema, min: () => schema };
	const api = {
		zod: { string: () => schema, number: () => schema, boolean: () => schema, array: () => schema, object: () => schema },
		pi: { AgentRegistry: { global: () => registry }, AskTool: class {}, settings: {} },
		getSessionName: () => undefined,
		registerTool: () => {},
		on: (name: string, handler: (event: Record<string, unknown>, ctx: unknown) => Promise<unknown>) => handlers.set(name, handler),
		events: {
			on(name: string, listener: (event: unknown) => void) {
				const listeners = channels.get(name) ?? new Set<(event: unknown) => void>();
				channels.set(name, listeners);
				listeners.add(listener);
				return () => listeners.delete(listener);
			}
		}
	};
	codeislandExtension(api as never, async payload => { sent.push(payload as Record<string, unknown>); return true; });
	const ctx = { cwd: "/repo", sessionManager: root.sessionManager, agent: { kind: "main", id: "Main", name: "main", depth: 0 } };
	const flush = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
	const fire = async (type: string, ref: Ref) => {
		for (const listener of registryListeners) listener({ type, ref });
		await flush();
	};
	const bus = async (name: string, event: unknown) => {
		for (const listener of channels.get(name) ?? []) listener(event);
		await flush();
	};
	cleanups.push(() => handlers.get("session_shutdown")!({}, ctx));
	return { sent, refs, root, handlers, ctx, flush, fire, bus };
}

describe("parent child observation", () => {
	test.each(["seance", "task", "scout", "reviewer", "security-reviewer", "sonic", "custom-worker"])("observes %s without loading its extension", async agent => {
		const h = harness();
		await h.handlers.get("session_start")!({}, h.ctx);
		const child = session(`${agent}-session`);
		const ref: Ref = { id: agent, kind: "sub", parentId: "Main", displayName: agent, status: "running", session: null };
		h.refs.set(agent, ref);
		await h.fire("registered", ref);
		ref.session = child;
		await h.bus("task:subagent:lifecycle", { id: agent, agent, status: "started" });
		child.emit({ type: "agent_start" });
		child.emit({ type: "tool_execution_start", toolCallId: "read-1", toolName: "read", args: { path: "file.ts" }, intent: "Reading child evidence" });
		child.emit({ type: "tool_execution_end", toolCallId: "read-1", toolName: "read", isError: true });
		child.emit({ type: "agent_end", messages: [], isTerminal: false });
		await h.flush();
		const mine = () => h.sent.filter(event => event.session_id === `pi-${agent}-session`);
		expect(mine().map(event => event.hook_event_name)).toEqual(["SubagentStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure"]);
		expect(mine().every(event => event._parent_session_id === "pi-observer-root" && event.agent_type === agent)).toBe(true);
		expect(mine()[2]!.intent).toBe("Reading child evidence");
		expect(mine()[3]!.is_error).toBe(true);
		child.emit({ type: "agent_end", messages: [], isTerminal: true });
		await h.flush();
		expect(mine().at(-1)!.hook_event_name).toBe("Stop");
		child.emit({ type: "agent_start" });
		await h.flush();
		expect(mine().slice(-2).map(event => event.hook_event_name)).toEqual(["SubagentStart", "UserPromptSubmit"]);
		ref.status = "aborted";
		ref.session = null;
		await h.fire("status_changed", ref);
		expect(mine().slice(-2).map(event => event.hook_event_name)).toEqual(["SubagentStop", "SessionEnd"]);
		expect(child.listenerCount()).toBe(0);
	});

	test("scans live depth-zero clones but excludes another root", async () => {
		const h = harness();
		const clone = session("clone-session");
		h.refs.set("Clone", { id: "Clone", kind: "sub", parentId: "Main", displayName: "sub", status: "running", session: clone });
		h.refs.set("Other", { id: "Other", kind: "main", status: "running", session: session("other-root") });
		h.refs.set("Other.Child", { id: "Other.Child", kind: "sub", parentId: "Other", status: "running", session: session("other-child") });
		await h.handlers.get("session_start")!({}, h.ctx);
		await h.flush();
		expect(h.sent.some(event => event.session_id === "pi-clone-session" && event._parent_session_id === "pi-observer-root")).toBe(true);
		expect(h.sent.some(event => event.session_id === "pi-other-child")).toBe(false);
	});

  test("named advisors require review backlog, never configured readiness", async () => {
    const h = harness();
    h.root.advisors.push(
      { name: "Quality", status: "running", yielded: false, backlog: 0, isPaused: false },
      { name: "Security", status: "running", yielded: false, backlog: 1, isPaused: false },
      { name: "Disabled", status: "paused", yielded: true, backlog: 1, isPaused: true }
    );
    await h.handlers.get("session_start")!({}, h.ctx);
    await h.flush();
    expect(h.sent.filter(event => event.hook_event_name === "SubagentStart").map(event => event.agent_type)).toEqual(["advisor: Security"]);
    h.root.advisors[1]!.backlog = 0;
    h.root.emit({ type: "advisor_yielded" });
    await h.flush();
    expect(h.sent.at(-1)!.hook_event_name).toBe("Stop");
    h.root.advisors[0]!.backlog = 1;
    h.root.emit({ type: "turn_end" });
    await h.flush();
    expect(h.sent.at(-1)!.agent_type).toBe("advisor: Quality");
  });

  test("accepted task lifecycle closes a run when agent_end was deferred", async () => {
    const h = harness();
    const child = session("deferred-child");
    h.refs.set("Child", { id: "Child", kind: "sub", parentId: "Main", displayName: "seance", status: "running", session: child });
    await h.handlers.get("session_start")!({}, h.ctx);
    await h.bus("task:subagent:lifecycle", { id: "Child", agent: "seance", status: "completed" });
    expect(h.sent.filter(event => event.session_id === "pi-deferred-child").map(event => event.hook_event_name)).toEqual(["SubagentStart", "Stop"]);
  });

  test("late child steps never resurrect a completed run", async () => {
    const h = harness();
    const child = session("settled-child");
    h.refs.set("Child", { id: "Child", kind: "sub", parentId: "Main", displayName: "scout", status: "running", session: child });
    await h.handlers.get("session_start")!({}, h.ctx);
    child.emit({ type: "agent_end", isTerminal: true, messages: [] });
    await h.flush();
    h.sent.length = 0;
    child.emit({ type: "tool_execution_end", toolName: "read", toolCallId: "late" });
    await h.flush();
    expect(h.sent).toEqual([]);
  });

  test("nested child survives immediate parent's disposal with captured identity", async () => {
    const h = harness();
    const parent = session("parent-child");
    const child = session("grandchild");
    const parentRef: Ref = { id: "Parent", kind: "sub", parentId: "Main", displayName: "task", status: "running", session: parent };
    h.refs.set("Parent", parentRef);
    h.refs.set("Parent.Child", { id: "Parent.Child", kind: "sub", parentId: "Parent", displayName: "scout", status: "running", session: child });
    await h.handlers.get("session_start")!({}, h.ctx);
    await h.flush();
    parentRef.session = null;
    parentRef.status = "parked";
    await h.fire("status_changed", parentRef);
    child.emit({ type: "tool_execution_start", toolName: "read", toolCallId: "nested", args: {} });
    await h.flush();
    expect(h.sent.at(-1)!._parent_session_id).toBe("pi-parent-child");
    expect(h.sent.at(-1)!.session_id).toBe("pi-grandchild");
  });

	test("ignores historical parked refs and unregisters listeners on shutdown", async () => {
		const h = harness();
		h.refs.set("Old", { id: "Old", kind: "sub", parentId: "Main", status: "parked", session: null });
		await h.handlers.get("session_start")!({}, h.ctx);
		const child = session("late-session");
		await h.handlers.get("session_shutdown")!({}, h.ctx);
		h.sent.length = 0;
		const ref: Ref = { id: "Late", kind: "sub", parentId: "Main", status: "running", session: child };
		h.refs.set("Late", ref);
		await h.fire("registered", ref);
		await h.bus("task:subagent:lifecycle", { id: "Late", agent: "task", status: "started" });
		child.emit({ type: "agent_start" });
		await h.flush();
		expect(h.sent).toEqual([]);
	});
});

