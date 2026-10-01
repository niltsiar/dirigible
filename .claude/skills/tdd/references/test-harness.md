# The test process is not the app

A result that depends on a difference between the test process and the app proves only the harness. Before a check becomes manual because the test process says "no", drive the built app (`verify-this/references/driving-the-app.md`).

## Pixels and window chrome

- After an incremental update (a scroll, a dirty rect, a layer copy), a test of what the window shows reads a capture of the window on screen (`TimelineColorTests.capture`). Make it red with the input where a probe saw the fault.
- A test of the window chrome (the title, the subtitle, a toolbar item) reads the drawn view in the frame view (`window.contentView?.superview`). The `NSWindow` property can keep its value while the title bar does not draw it.

## Strings, values, and accessibility

- `L10n` gives the string keys, because `Bundle.main` is the test runner. A key is wider than most texts, so a layout test chooses its strings on purpose, and a layout must hold at any text width.
- `#expect(a == b)` of a `CGFloat` and a `Double` with the same value fails: convert both to `Double`.
- To prove that VoiceOver reaches an element, walk `accessibilityChildren()` from the window content view down to it. A direct call of its accessibility method proves nothing.

## Events and focus

- A synthetic `NSEvent` to `scrollWheel(with:)` does not act as an HID scroll does.
- A test process has no key window, so `NSApp.sendEvent` can give a synthetic key event to the window of another suite. Send it with `NSWindow.sendEvent` to the window of the test.
- A mouse-down that `NSWindow.sendEvent` gets is a first click: the window takes it to become key, and no view gets it. Send the mouse-down and the mouse-up to the view that `window.contentView?.superview?.hitTest(event.locationInWindow)` gives. First-click behavior stays a manual check.
- Prove a click on an `NSTableView` on the built app. In the test process, a mouse-down to the table with a posted mouse-up ended the process with exit 0 and no report.
- All windows of the test process share one SwiftUI field editor, and a text field of a parallel suite can take it between a poll and a key. Get the name field editor with `focusedNameEditor(in:)`.

## The pool, preferences, and seams

- A blocking gate (a semaphore) on a pool thread blocks that thread: in async test code, and in a synchronous hook that a `@concurrent` or detached function calls. When every pool thread waits, the test that opens the gates cannot run. Hold the work at an async seam with `AsyncGate`, and make a new test seam `async` when async code calls it. `Gate.waitOnce` is `noasync`, so the compiler refuses it only in async code.
- Pin a user preference that a test depends on (for example window tabbing) before the test opens a window. The same applies to each seam and environment value (free disk bytes, an announce hook, a clock): work that starts at open uses the value at open. When a seam can be set only after construction, start the work again with the seam and wait for the newest run to end. When a fix removes a cancel or a "newest wins" step, grep every test helper that sets a seam after construction.
