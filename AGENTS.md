# Agent instructions

## Debugging the macOS app

CodeIsland is an `LSUIElement` app. A successful build does not prove window, hover, focus, or restoration behavior. Test those changes against the signed app bundle and inspect the live macOS Accessibility tree.

### Reliable smoke test

1. Build with `./build.sh`.
2. Kill all existing instances with `pkill -x CodeIsland`. Verify `pgrep -x CodeIsland` returns nothing. This avoids testing an installed or stale copy.
3. Launch exactly one rebuilt instance with `open -n .build/release/CodeIsland.app`. Verify `pgrep -x CodeIsland | wc -l` returns `1`.
4. Wait for the launch animation to settle before inspecting state.
5. Exercise the public interaction path. Do not call controllers directly when testing user behavior.
6. Reinspect state after every action, then quit all test instances.

The terminal or agent host needs macOS Accessibility permission. Check it with:

```bash
osascript -e 'tell application "System Events" to get UI elements enabled'
```

Inspect window identity and geometry with:

```bash
osascript -e 'tell application "System Events" to tell process "CodeIsland" to get {name, role, subrole, position, size} of every window'
```

The island is an unnamed `AXSystemDialog`. Settings is an `AXStandardWindow` named `CodeIsland Settings`. To distinguish a populated window from an empty shell, inspect `entire contents` and look for expected labels and controls:

```bash
osascript -e 'tell application "System Events" to tell process "CodeIsland" to get entire contents of every window'
```

Use Accessibility roles and labels to find controls, then invoke `AXPress`. Do not hardcode button indices or screen coordinates. Screenshots alone are weak evidence for transparent or borderless windows.

For hover bugs, move the real pointer onto a visible island wing. A CoreGraphics `.mouseMoved` event is more reliable than only warping the cursor. Derive the target from the live accessibility position instead of assuming a display size.

Smart Suppress intentionally blocks hover expansion when the active session's terminal is foreground. This commonly applies while testing from Ghostty or Herdr. Focus Finder or another unrelated app before judging hover behavior:

```bash
osascript -e 'tell application "Finder" to activate'
```

For launch or Settings regressions, verify this sequence:

1. Clean launch shows the island and no Settings window.
2. Hover expands when Smart Suppress does not apply.
3. The visible gear button opens one populated Settings window.
4. Closing Settings removes it.
5. A full quit and clean relaunch does not restore Settings unexpectedly.

Remove temporary scripts and captured output after verification. Keep a permanent test only for stable behavior that can run unattended.
