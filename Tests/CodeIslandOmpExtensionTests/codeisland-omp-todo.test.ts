import { describe, expect, test } from "bun:test";

// Dynamic import exception: the module calls `detectTty()` and reads `process.env.HOME`
// at load time to derive the bridge path. Static import cannot be used here because the
// HOME env must be patched before the module initialises to prevent bridge file access.
const originalHome = process.env.HOME;
process.env.HOME = "/tmp/codeisland-omp-extension-tests-todo";
const { ompTodoSnapshot } = await import(
  "../../Sources/CodeIsland/Resources/codeisland-omp?todo-tests"
);
if (originalHome === undefined) {
  delete process.env.HOME;
} else {
  process.env.HOME = originalHome;
}

describe("ompTodoSnapshot", () => {
  test("returns null only when phases is undefined (tool has not run)", () => {
    expect(ompTodoSnapshot(undefined)).toBeNull();
  });

  test("returns empty todos snapshot when phases array is empty (op=clear/init clears bar)", () => {
    expect(ompTodoSnapshot([])).toEqual({ todos: [] });
    // A phase with no tasks also produces an empty snapshot — all tasks were completed/removed.
    expect(ompTodoSnapshot([{ name: "Tasks", tasks: [] }])).toEqual({ todos: [] });
  });

  test("flattens a single default phase to bare titles", () => {
    const snapshot = ompTodoSnapshot([
      {
        name: "Tasks",
        tasks: [
          { content: "Read code", status: "completed" },
          { content: "Fix bug", status: "in_progress" },
          { content: "Run tests", status: "pending" },
        ],
      },
    ]);
    expect(snapshot).toEqual({
      todos: [
        { content: "Read code", status: "completed" },
        { content: "Fix bug", status: "in_progress" },
        { content: "Run tests", status: "pending" },
      ],
    });
  });

  test("prefixes the phase name onto multi-phase tasks", () => {
    const snapshot = ompTodoSnapshot([
      { name: "Foundation", tasks: [{ content: "Scaffold", status: "completed" }] },
      { name: "Auth", tasks: [{ content: "Wire OAuth", status: "in_progress" }] },
    ]);
    expect(snapshot).toEqual({
      todos: [
        { content: "Foundation: Scaffold", status: "completed" },
        { content: "Auth: Wire OAuth", status: "in_progress" },
      ],
    });
  });

  test("maps abandoned to completed and blocked to pending", () => {
    const snapshot = ompTodoSnapshot([
      {
        name: "Tasks",
        tasks: [
          { content: "Dropped path", status: "abandoned" },
          { content: "Waiting on API", status: "blocked", blocker: "needs token" },
        ],
      },
    ]);
    expect(snapshot).toEqual({
      todos: [
        { content: "Dropped path", status: "completed" },
        { content: "Waiting on API", status: "pending" },
      ],
    });
  });
});
