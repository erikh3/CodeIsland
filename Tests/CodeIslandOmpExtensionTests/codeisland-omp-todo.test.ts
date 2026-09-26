import { describe, expect, test } from "bun:test";

// The module reads HOME while loading; isolate it from the real environment.
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
  test("returns null for empty or missing phases", () => {
    expect(ompTodoSnapshot(undefined)).toBeNull();
    expect(ompTodoSnapshot([])).toBeNull();
    expect(ompTodoSnapshot([{ name: "Tasks", tasks: [] }])).toBeNull();
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
