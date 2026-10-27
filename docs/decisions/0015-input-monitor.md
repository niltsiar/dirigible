# 0015. Input monitor: an explicit toggle, a device writer with no take, and one device-list listener

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-10-27, run `2026-10-27-armed-app-track`. An armed app track gets a monitor writer with a tap (0029 **Monitor**). The turn puts the writer in the state. A task after the turn starts it after the first attach try of each device monitor writer, by the start deadline (the A5 order of 0030), only while the monitor still holds it and no take writer exists. So no monitor wait delays a stop, Retry Finalize, or a later turn. The microphone status is read only for a device route (**Owner**).
- Amended: 2026-10-10, run `2026-10-10-record-monitor-button`. The UI name of Monitor Inputs is now Input Levels (toolbar label Levels; Spanish Niveles de entrada and Niveles), because it shows meters and plays no sound. Its key (Shift-Command-M), its toolbar identifier, and its symbol stay. This record keeps the old name in its older lines.
- Amended: 2026-10-10. The window meters the listened tracks of the record monitor, and the armed tracks while Monitor Inputs is on. A listen needs no arm. `Studio.monitor(armed:)`, the hand-over, and the device list do not change (see 0044).
- Amended: 2026-10-03. The device list also watches the default devices and the output data source (run 6b).
- Amended: 2026-09-27. Monitor Inputs is a toolbar toggle and a Record menu item with Shift-Command-M. The check box in the window goes (see 0023).

## Context

Release 1 run 3b (`docs/requirements/releases.md`) adds the meter of an armed track before a take, and a device-list listener for the menus of the session window. The record-ui run split both off (0014). Today the meter exists only during a take, and the window polls the device list every 2 s while it is key and idle.

Constraints: monitoring writes no file; the IOProc only copies into the ring and every callback is a C function of a nonisolated type (0013); the main actor does no file and no HAL work (0013); the app must not hold the microphone when no track is armed; the monitor stops, or hands over with no gap, when a take starts. At window open, 0014 arms the routed tracks.

Hindenburg shows the input meter of an armed track, and Record Monitor (to hear the input) is a separate switch (`docs/research/document-window.md` section 8).

Probes on 2026-09-24 (macOS 15.7.9, x86_64, Swift 6.2.4; `.scratchpads/runs/2026-09-24-input-monitor/probe/output.txt`), with no input device and no prompt:

- Q1. Two C IOProcs on one output device in one process: both run. After the stop and destroy of one return, it gets 0 calls, and the other has 0 sample-time gaps in 5 of 5 rounds. The device keeps running. For an input device this is an inference.
- Q3. A C listener on `kAudioHardwarePropertyDevices` gets 2 calls when the process makes and destroys a private aggregate device, 0 calls with no change, and no call on the main thread. After its removal returns, it gets 0 calls.
- Q4. `kAudioProcessPropertyIsRunningInput` of a process object tells if a process runs audio input. A process with no audio client has object 0.

## Decision

**Start rule.** "Monitor Inputs" is a toggle of each window: a button in the window and an item in the Record menu, with no key. It is off at each window open and is not saved. While it is on, the meter runs for each armed track with a route, while no take records. "On arm" would open the microphone at each window open (0014 arms the routed tracks), also when the user only edits. "On window focus" would stop the meter when the user sets levels with the call app in front, and would make the microphone indicator blink at each switch. The toggle is a user act, so the microphone request comes from a user act, the same as Record.

**Owner.** `Studio.monitor(armed:)` sets the request. `Studio` runs each change of the monitor in its own order (a monitor turn), not in the package write chain. So a change never interleaves with another change, the hand-over, or the come back, and it never waits for an autosave, a start save, or a finalize. A finalize can take minutes, and the microphone must go off within one drain when the user turns the monitor off, in every transport state. A start step or a stop step takes a monitor turn only for the hand-over and the come back. Code that holds a monitor turn never waits for a package write. The last call wins. An empty request, or one with no routed track, releases every monitor device before the call returns. While take writers exist, the call stores the request. A change makes its whole state change (the monitor writers and `liveTracks`) before its first await, and then waits for the finish of each released writer. So a start step that runs during that wait keeps its entries, and a new writer of a device can attach before the old one detaches, as at the hand-over. When a track of the request has a device route, the library reads the microphone status and throws `.microphoneAccess` when it is not granted; the window requests the access and calls again (0013). A request with app routes only reads no microphone status (0030 **Start**).

**The monitor writer.** A monitor is a `DeviceWriter` with no take (`files: nil`): the same IOProc, ring, drain, watchdog, retry, and device events as a take. `TrackSegments.write` with no take computes the peaks and never opens a segment. The ring holds 1 s, not 10 s: a full ring loses only meter data. A monitor writer starts from a placeholder device (the UID and the highest routed channel) and takes the real device at its first attach, so a device that is missing at the start shows "device lost" and comes back through the path of 0013. A monitor writer keeps at most 64 detached inputs. At the limit it attaches no more until the next monitor start, and its tracks show the state `.retryStopped` with the text "Stopped retrying. Turn Monitor Inputs off and on." Only an appearance that attaches keeps an input, so a device that is only absent never reaches the limit. A present device whose attach fails at each 1 s try reaches it in about 64 s; a device that attaches and then sends no record, in about 11 min. The meter feed is `Studio.liveTracks`, with the new states `.monitoring` and `.retryStopped`.

**App Nap.** While a monitor writer runs, `Studio` holds the latency-critical `ProcessInfo` activity, with no IOPM assertion. With a 1 s ring, App Nap on a hidden window could delay the drain past the ring and give false dropped frames. The activity lets the system sleep. A take keeps its own sleep assertion and activity (0004, 0014).

**Hand-over.** In the start step, after the start save, the take writers are new, as in 0013. The step sets the sleep assertion and the disk watcher, clears `isStarting`, and calls one hand-over function (also used by the test seam of the start). In a monitor turn, the function waits until each take writer tried its first attach, and then finishes each monitor writer. A stop that comes during the hand-over waits for the start step and does not throw `.busy`. So the device keeps running, and a slow device does not restart its IO at Record (Q1). A monitor report after the hand-over changes nothing: each monitor writer reports with its own number, and `begin` replaces the entries. A start that throws keeps the monitor as it was.

**Come back.** In the stop step, after the take writers finish, the stored request applies again in a monitor turn. The step returns the turn before the finalize, so a change of the monitor during the finalize runs at once. A pending take does not stop the monitor.

**Release.** `monitor(armed: [])`, the hand-over, and `settle()` release the devices. `settle()` empties the request and applies it first, then stops a take. The window turns its toggle off before it settles (close and Quit), so a cancelled close or quit shows the toggle off, the same as the monitor. No `deinit` releases a device. Every app path settles a studio before it drops it (0014).

**Device list.** `DeviceList.shared` (`@Observable @MainActor`, in `DirigibleAudio`) installs one C listener on the device list, the default input device, and the default output device of the system object, with no client data, in its first read off the main actor. The main actor makes no HAL call. It never removes them. At each call, and when a window becomes key, it reads `InputDevice.all()` and the defaults (`AudioDefaults`: the default input UID and the speaker flag) off the main actor, one read at a time. Each read adds the same listener to the output data source of the default output device, once per device, before it reads the speaker flag. So no data source change falls between the add and the read. The flag is true only for transport `bltn` with data source `ispk`: a headphone plug changes the data source of the same device (probe P6). Each window reads its menus from it. The 2 s poll goes. A route whose device is not in the list shows "missing"; a monitored track whose device goes away shows "device lost".

**CLI (0011).** No `dirigible monitor` and no `dirigible devices --watch`. The monitor writes nothing to a package, and its output is a live meter for a person; a command would hold the package lock only to meter; `dirigible record` already drives the same IOProc, ring, drain, and peak path. A watch mode needs a long-running loop, a stop on SIGINT, and an output frame, and no script needs it now. A test with a private aggregate device proves the listener with no hardware.

## Consequences

- 0013 gets an amended line: a device writer with no take is a monitor; it writes no file, has a 1 s ring, and keeps at most 64 inputs.
- 0014 gets an amended line: the meter before a take and the device listener are in 0015; the 2 s poll goes.
- 0011 gets an amended line: no command for the monitor and the device list (0015).
- For the time of one attach at Record, and at a change of the tracks of a monitored device, two IOProcs run on one device. On an input device this rests on the Q1 inference until manual check M3 of the run passes. If it fails, the step finishes the monitor before `begin`, and the meter drops for the start time of the device.
- Each monitor start keeps about 230 bytes for the process life (one device-list box and one input, 0013), and at most 12.8 KB per device (64 inputs) with no user action.
- `Studio` has two orders: the package write chain and the monitor turns. Code that holds a monitor turn must never wait for a package write, or the two can wait for each other.
- While the monitor runs, App Nap is off for the app, also with the window hidden.
- A device at the keep limit needs the user to turn the monitor off and on.
- A Bluetooth headset can switch to its call profile when the monitor opens its input.
- A channel-count change of a device that stays in the list shows at the next window focus or list change.
- A studio that is dropped with no `settle()` keeps its monitor devices. Tests call `settle()` or `monitor(armed: [])`.

## Alternatives considered

- **Promote the monitor writer into the take** (one IOProc; retarget the writer at the take start). Rejected: a take writer that lived before the take carries its counters, watchdog clock, report closure, gaps, and arm map into the take, and each is a new transition to test. With new take writers, every 0013 rule holds as it is.
- **A monitor owner in the app** (`InputMonitor`) that the take adopts. Rejected: the order rule of the hand-over would be in two modules.
- **A `Content` enum in `DeviceWriter`** so a monitor cannot write by type. Rejected: `DeviceWriter` uses eight members of `TrackSegments`, and each would need a forward. One guard with a mutation test covers it.
- **Meter on arm, or on window focus.** Rejected for the reasons in "Start rule".
- **A device-list stream per window** with a removal at close. Rejected: a kept box, a lock, and a removal rule per window, where one listener for the process needs none.
- **Stop the monitor, then start the take.** Kept as the fallback of M3.
