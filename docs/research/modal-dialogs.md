# How macOS apps and automation interfaces behave when a command arrives during a modal dialog

Date: 2026-10-22

## Scope and method

This file answers four questions for the refusal of a Dirigible `export` while the window shows a dialog. It uses primary sources: Apple documentation, Apple SDK headers, vendor documentation, vendor source code, and the MCP specification. It lists each claim with no owner source as "Inference:" and repeats it in "Open questions".

No probe ran. The caller named no probe folder. Local reads of installed app bundles and SDK headers ran, with no build.

A note on tool use: the page text for the Apple, Adobe, and MCP sources came through a fetch tool. The quotes for the AppleScript Language Guide, the Sheets guide, and the Adobe `executeAsModal` page were checked against the raw page text. The Microsoft pages, the MCP pages, and the Playwright source were read as raw text.

## 1. Apple Events and AppleScript

### Timeout and error code

- F1. AppleScript waits 2 minutes (120 s) for an application to answer a command. After that, AppleScript stops the script and returns the error "event timed out". Source: AppleScript Language Guide, "with timeout Statements".
- F2. A `with timeout of N seconds` statement replaces the 2-minute default for the commands inside it. The timeout does not cancel the operation in the application. It stops only the script. Source: AppleScript Language Guide, "with timeout Statements".
- F3. The error number is -1712 ("The Apple event has timed out."). Source: AppleScript Language Guide, error codes table. The guide's `with timeout` section gives the text but no number.
- F4. At the Apple Event Manager level, `kAEDefaultTimeout` is -1, "timeout value determined by AEM", and `kNoTimeOut` is -2, "wait until reply comes back, however long it takes". Source: `AEDataModel.h` in the local macOS SDK. An archived Inside Macintosh page (marked obsolete) says the Apple Event Manager uses "about one minute" for `kAEDefaultTimeout`. The two defaults differ (2 minutes for AppleScript, about 1 minute for a raw `AESend` caller). Treat the 1-minute value as historical.
- F5. A timeout error "does not necessarily mean that the server failed to perform the requested action". The server "might still be processing the Apple event, and it might still send a reply". Source: Inside Macintosh, "Dealing With Timeouts" (obsolete). If the sender sets `kAEQueueReply` or `kAENoReply`, the Apple Event Manager ignores the timeout. Same source.
- F6. A command that the target has no handler for returns at once with `errAEEventNotHandled` (-1708). Source: same Inside Macintosh page, and the AppleScript error table.

### Window-modal sheet open

- F7. A sheet is "document modal". While it is open, "normal program execution continues" and "events are handled by the Application Kit just as for any other window". The sheet calls return at once. Source: Apple, "Sheet Programming Topics", About Sheets.
- Inference: an Apple event that arrives while a sheet is open reaches its handler in the normal way, because the main run loop still runs in its default mode. The Sheets guide does not mention Apple events. No source confirms this for Apple events. It is an open question (see Q1).

### App-modal dialog open (`NSAlert.runModal`, `NSApp.runModal`)

- F8. `runModalForWindow:` "monopolizes events for the specified window" until `stopModal`, `abortModal`, or `stopModalWithCode:` runs. Source: Apple, "Window Programming Guide", How Modal Windows Work. The page does not mention Apple events.
- F9. In `NSModalPanelRunLoopMode`, "only sources relevant to the modal panel would deliver events to the thread". A source that is not in the current mode holds its events until the run loop runs in a matching mode. Source: Apple, "Threading Programming Guide", Run Loop Management. The page does not say which sources run in modal mode.
- F10. The SDK header `AEMach.h` says that, when HIToolbox is in use, "AppleEvents are dispatched through the main event loop". Source: `AEMach.h` in the local macOS SDK (`AEGetRegisteredMachPort`).
- Inference: during an app-modal dialog, an incoming Apple event waits until the modal loop ends. If the dialog stays open longer than the sender's timeout, the sender gets -1712 and the event can still run later. No Apple source says this. It is an open question (see Q1). Do not state it as fact in the agent manual.

### What an app can do with an Apple event while it shows a dialog

- F11. A Cocoa app can suspend the Apple event (or the script command), show a sheet, put the answer in the reply after the user dismisses the sheet, and then resume. The calls are `NSAppleEventManager.suspendCurrentAppleEvent`, `NSScriptCommand.suspendExecution`, and the matching resume calls. Source: Apple, "Cocoa Scripting Guide", Handling Apple Events (the section "Suspending and Resuming Apple Events and Script Commands").
- F12. The sender can set an interaction level. `kAENeverInteract` means the server "should never interact with the user"; then `AEInteractWithUser` returns `errAENoUserInteraction`. `kAECanInteract` is the default for a local target. Source: Inside Macintosh, `AESend` (obsolete). The error number is -1713, "User interaction is not allowed". Source: AppleScript Language Guide, error codes table. The constants are in `AEDataModel.h`.
- Inference: the interaction level is the nearest Apple convention for "the caller says whether the app may show UI for this command". It does not fit the Dirigible case, where the dialog is already open before the command arrives. No source ties the two together.

## 2. Final Cut Pro, Logic Pro, GarageBand, Hindenburg PRO

- F13. Final Cut Pro. Apple says to send FCPXML with the `open` command (the `Open Document` Apple event), from AppleScript. Final Cut Pro then "displays the Open Library dialog so your user can choose where the content should go". A library location in the FCPXML `import` option avoids that choice. Apple says AppleScript lets Final Cut Pro "identify the app that's sending the request", so it can report an error "or prompt for user action". Source: Apple, "Sending Data Programmatically to Final Cut Pro". The page documents no behavior for a command that arrives while a modal dialog is open. Apple does not document a busy state or a busy error code on that page.
- F14. Final Cut Pro 12.3 local check. The bundle file `Contents/Resources/ProEditor.sdef` includes the Cocoa standard suite and one custom command, `get`, with read-only library classes (library, event, project, sequence). It has no command or property for window or dialog state. Source: the file on the test Mac (read, not run).
- F15. Logic Pro 12.4 and GarageBand 10.4.14 local check. `Info.plist` has `NSAppleScriptEnabled` set to 1 for both apps. A `find` for `*.sdef`, `*.scriptSuite`, and `*.scriptTerminology` in both bundles returned no file. Source: local bundles (read, not run). This is a negative file search, not proof that the apps have no scripting.
- F16. Logic Pro. No Apple document that was found describes the behavior of scripting, Scripter, a control surface, or MIDI remote when a modal dialog is open. An Apple Developer Forums thread has community posts (not Apple staff) that say the Logic Pro scripting is minimal. Source: https://developer.apple.com/forums/thread/115355. The one Apple DTS post in the thread only shows how to open a dictionary. The Logic Pro User Guide was not read page by page.
- F17. GarageBand and Hindenburg PRO. No documented behavior was found. Two searches for Hindenburg PRO scripting or automation returned no Hindenburg page. Do not infer a behavior for either product.

## 3. Other interfaces that report a blocked state to the caller

### Microsoft COM (Office, Visual Studio automation)

- F18. A COM server can return `SERVERCALL_RETRYLATER` from `IMessageFilter::HandleInComingCall`: "The application cannot handle the call at this time. An application might return this value when it is in a user-controlled modal state." `SERVERCALL_REJECTED` is for "an unforeseen problem". Source: Microsoft Learn, `IMessageFilter::HandleInComingCall`.
- F19. The caller's `RetryRejectedCall` decides. A return of -1 cancels the call, and COM returns `RPC_E_CALL_REJECTED`. A value from 0 to 99 retries at once. A value of 100 or more means COM waits that many milliseconds, then retries. Microsoft says: retry `SERVERCALL_RETRYLATER` calls silently, and after "about 30 seconds" show a busy dialog. Source: Microsoft Learn, `IMessageFilter::RetryRejectedCall`. Microsoft says this retry option exists for "background tasks executing macros or scripts".
- F20. The error pair that automation callers see is `RPC_E_CALL_REJECTED` 0x80010001 ("Application is busy") and `RPC_E_SERVERCALL_RETRYLATER` 0x8001010A ("Call was rejected by callee"), as labeled by the Visual Studio page. Source: Microsoft Learn (archived), "How to: Fix 'Application is Busy' and 'Call was Rejected By Callee' Errors". That page says the cause is thread contention, not a dialog. Neither code names the dialog or the action that clears it. The `HandleInComingCall` inputs carry only the call type, the caller thread, a tick count, and the interface and method.
- Inference: Excel returns 0x800AC472 while a dialog or cell edit is active. Only vendor and forum posts (for example PyXLL support) say this, in search results. No Microsoft primary page was found. Do not cite it as fact.

### Adobe

- F21. Photoshop UXP `executeAsModal`. Only one plugin can hold the modal state. Before Photoshop 25.10, a second call threw an error with the text "host is in a modal state". From 25.10, the request goes into a queue and retries until the `timeOut` option ends (default 1 second). The error text then "will include the plugin that held that existing state", for example "Plugin: com.adobe.testPlugin is running a modal command". The sample code tests `e.number == 9`. Source: https://developer.adobe.com/photoshop/uxp/2022/ps_reference/media/executeasmodal/. This is a plugin lock, not a user dialog. The page gives no way to clear another plugin's state. The user can cancel with Escape or the progress bar.
- F22. InDesign. Scripts get the error "Cannot handle the request because a modal dialog or alert is active", and `app.modalState` reports the condition. The error does not name the dialog. Source: Adobe Community threads only (for example https://community.adobe.com/t5/indesign-discussions/cannot-handle-the-request-because-a-modal-dialog-or-alert-is-active/m-p/12042648/highlight/true). No Adobe reference page was found, so the text has no owner source. The same threads say a script can set `app.scriptPreferences.userInteractionLevel = UserInteractionLevels.NEVER_INTERACT` to suppress dialogs that the script itself triggers. That is also a community claim.

### Blender

- F23. A Python operator that cannot run in the current context raises `RuntimeError: Operator bpy.ops.action.clean.poll() failed, context is incorrect`. The docs say the cause is hard to find: "the only way to eventually know what is causing the error is to read the source code for the poll function". Blender can attach a reason with `bpy.types.Operator.poll_message_set`, for example `bpy.ops.gpencil.draw.poll() Failed to find Grease Pencil data to draw into`, but "it's currently not used much". Source: https://docs.blender.org/api/5.0/info_gotchas_operators.html. Blender gives no retry hint. This is a context failure, not a modal dialog.

### Playwright MCP (an MCP server that does report a blocking dialog)

- F24. When a page shows a dialog or a file chooser, Playwright MCP records a "modal state" with a description such as `"confirm" dialog with message "..."`. Every tool response lists it as `- [<description>]: can be handled by <tool name>`, and the dialog tool is `browser_handle_dialog`. Source: `packages/playwright-core/src/tools/backend/tab.ts` and `response.ts` in https://github.com/microsoft/playwright (main branch, read 2026-10-22).
- F25. A tool that does not clear the modal state returns the error `Error: Tool "<name>" does not handle the modal state.` The tool that clears it returns `Error: The tool "<name>" can only be used when there is related modal state present.` if no dialog is open. Source: `packages/playwright-core/src/tools/backend/tool.ts`, same repository. The error text itself names no dialog and no clearing tool. The dialog and the clearing tool appear in the "Modal state" section of the response that goes with the error. This is a design in which the error and the state list work together.
- F26. In Playwright MCP, no retry hint is given. The state list names the action that clears the dialog, and the agent acts on it. Source: same files.

## 4. MCP guidance

- F27. MCP separates two error kinds. Protocol errors (unknown tool, malformed request, server error) are JSON-RPC errors "that models are less likely to be able to fix". Tool execution errors (API failures, input validation errors, business logic errors) go in a result with `isError: true`. Source: MCP specification 2026-07-28, Tools, Error Handling. https://modelcontextprotocol.io/specification/latest/server/tools
- F28. The specification says tool execution errors "contain actionable feedback that language models can use to self-correct and retry with adjusted parameters". Clients "SHOULD provide tool execution errors to language models to enable self-correction". Source: same page. The page does not say what the text must contain. Its example text is plain: "Invalid departure date: must be in the future. Current date is 08/08/2025."
- F29. SEP-1303 (status Final) gives the reason: a model that does not see the error text "repeats the same mistake multiple times". Source: https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors.md
- F30. The 2026-07-28 schema defines no retry-after field, no busy status, and no error-code taxonomy for tool results. A text search of `schema.md` for "retry" and "busy" found only the `input_required` result type. Source: https://modelcontextprotocol.io/specification/2026-07-28/schema.md (searched 2026-10-22). A retry hint for a busy window is therefore free text in the result.
- F31. The `input_required` result (Multi Round-Trip Requests) lets a server ask the user for input during a `tools/call`, for example by elicitation. The client then retries the call with the answers. Servers "MUST NOT assume that clients will fulfill the `inputRequests` or retry". Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr.md. It supports a "ask the person, then retry" flow. It does not describe waiting for an app dialog.
- F32. MCP Tasks (an extension) cover long-running calls that finish later. The pages exist in the site index (https://modelcontextprotocol.io/extensions/tasks/overview.md). This research did not read them. Their fit for "wait for the dialog" is an open question.
- F33. The Tools page tells clients to "Implement timeouts for tool calls" and servers to "Rate limit tool invocations". Source: MCP specification 2026-07-28, Tools, Security Considerations. A call that waits for a user to close a dialog needs a bound that is shorter than the client timeout. The spec gives no number.

## Observed patterns (for the decision)

These points restate the facts above. They are not new claims.

- Three interfaces refuse at once and say that the app is busy: COM `RETRYLATER`, InDesign, and Dirigible today. None of the three names the dialog in the code. Only COM documents a retry rule (silent retry, then ask the user after about 30 seconds).
- Two interfaces solve the naming problem. Playwright MCP lists each open dialog and the tool that clears it in every response. The Photoshop 25.10 error names the plugin that holds the lock.
- Two interfaces wait. Photoshop 25.10 queues the call for `timeOut` (default 1 second). AppleScript waits 2 minutes by default (F1), then times out, and the operation can still run later (F2).
- Apple documents one way to answer an Apple event after a sheet: suspend, then resume (F11).

## Open questions

Q1. Does a Cocoa app handle an Apple event while it shows (a) a sheet, and (b) an `NSAlert.runModal` or `NSApp.runModal` dialog? If (b) delays the event, does the event run after the dialog closes? No Apple source answers this (F7 to F10 give only indirect facts). Proposed probe, to run in a folder that the caller names: a small AppKit app with a scriptable `get name` command and a menu item that opens each dialog type. From a shell, run `osascript -e 'with timeout of 10 seconds' -e 'tell application "Probe" to get name' -e 'end timeout'` while each dialog is open. Record: time to answer, the error number (-1712 or none), and whether the command ran after the dialog closed. Run it in the foreground with a Bash timeout of 10 minutes or less, with `scripts/with-lock.sh scripts/probe.sh <folder> <command>`.

Q2. For Dirigible's own refusal text, which of these cases is the most common agent gesture: the Export save panel left open (a sheet on the window), an `NSAlert`, or a panel from another menu command? This was not checked here. The Playwright design (F24, F25) fits any of them only if Dirigible can describe each dialog in words.

Q3. Does Microsoft document Excel's 0x800AC472 as a dialog or edit-mode refusal? Only vendor and forum text was found (F20 Inference).

Q4. Do the MCP Tasks pages offer a pattern for "pending until the user acts"? Not read (F32).

Q5. Adobe has no reference page that was found for the InDesign modal error text or `app.modalState` (F22).

Q6. Logic Pro, GarageBand, Hindenburg PRO: no documented modal behavior was found (F16, F17). A deeper read of the Logic Pro User Guide for Scripter and control surfaces was not done.

## Sources

- AppleScript Language Guide, control statements (`with timeout`): https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html
- AppleScript Language Guide, error codes: https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_error_codes.html
- Inside Macintosh, "Dealing With Timeouts" (obsolete): https://developer.apple.com/library/archive/documentation/mac/IAC/IAC-201.html
- Inside Macintosh, `AESend` (obsolete): https://developer.apple.com/library/archive/documentation/mac/IAC/IAC-226.html
- Local SDK headers `AEDataModel.h` and `AEMach.h`: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/AE.framework/Versions/A/Headers/`
- Sheet Programming Topics, About Sheets: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Sheets/Concepts/AboutSheets.html
- Window Programming Guide, How Modal Windows Work: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/UsingModalWindows.html
- Threading Programming Guide, Run Loop Management: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html
- Cocoa Scripting Guide, Handling Apple Events: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptableCocoaApplications/SApps_handle_AEs/SAppsHandleAEs.html
- Apple, Sending Data Programmatically to Final Cut Pro: https://developer.apple.com/documentation/professional-video-applications/sending-data-programmatically-to-final-cut-pro.md
- Local bundles read: `/Applications/Final Cut Pro.app/Contents/Resources/ProEditor.sdef` (12.3), `/Applications/Logic Pro.app` (12.4), `/Applications/GarageBand.app` (10.4.14)
- Apple Developer Forums, Logic Pro AppleScript thread (community posts): https://developer.apple.com/forums/thread/115355
- Microsoft Learn, `IMessageFilter::HandleInComingCall`: https://learn.microsoft.com/en-us/windows/win32/api/objidl/nf-objidl-imessagefilter-handleincomingcall
- Microsoft Learn, `IMessageFilter::RetryRejectedCall`: https://learn.microsoft.com/en-us/windows/win32/api/objidl/nf-objidl-imessagefilter-retryrejectedcall
- Microsoft Learn (archived), Application is Busy / Call was Rejected By Callee: https://learn.microsoft.com/en-us/previous-versions/ms228772(v=vs.140)
- Adobe, Photoshop UXP `executeAsModal`: https://developer.adobe.com/photoshop/uxp/2022/ps_reference/media/executeasmodal/
- Adobe Community, InDesign modal dialog error (community, not an owner source): https://community.adobe.com/t5/indesign-discussions/cannot-handle-the-request-because-a-modal-dialog-or-alert-is-active/m-p/12042648/highlight/true
- Blender Python API, Using Operators: https://docs.blender.org/api/5.0/info_gotchas_operators.html
- Playwright MCP source: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/tools/backend/tool.ts, `tab.ts`, and `response.ts` (same directory)
- MCP specification 2026-07-28, Tools: https://modelcontextprotocol.io/specification/latest/server/tools
- MCP specification 2026-07-28, schema: https://modelcontextprotocol.io/specification/2026-07-28/schema.md
- MCP specification 2026-07-28, Multi Round-Trip Requests: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr.md
- MCP SEP-1303: https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors.md
- MCP index (Tasks extension pages, not read): https://modelcontextprotocol.io/llms.txt
