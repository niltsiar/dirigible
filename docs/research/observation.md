# Research: Observation cancel cost and registration build-up

Date: 2026-10-16

Goal: decide if the hang (main thread at 100 percent, `ObservationTracking.cancel()` -> `State.cancel(_:)` -> `Set.remove` -> `_NativeSet.copy()`, macOS 14.6) is an O(n^2) cancel of registrations that built up. Also decide if macOS 15 has the same code.

No build, probe, or test ran. All facts come from GitHub files at fixed tags (read-only API).

## Answer in short

- Finding 1: On Swift 5.9 and 5.10 (macOS 14.x), `State.cancel(_:)` copies the whole `Set<Int>` for each removed key path. This is O(n) for each cancel. The sample matches this code.
- Finding 2: The copy was removed in swiftlang/swift PR #73288 (merged 2024-04-30). It is in Swift 6.0, 6.1 and 6.2. It is not in 5.9, 5.10, or the `release/5.10` branch.
- Finding 3: Apple states no rule about old tracking when a body runs again. The needed fact is not public. See "Inference:" lines.
- Finding 4: No Apple or Swift-team report of the "never-changing property keeps registrations" case was found.

## 1. Source of `ObservationRegistrar.State`

File path: `stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift` (R) and `ObservationTracking.swift` (T).

### 1.1 Swift 5.9 and 5.10 (tags swift-5.9-RELEASE, swift-5.10-RELEASE)

R is the same in both tags, except for doc comments. The state holds two tables:

```swift
private var id = 0
private var observations = [Int : Observation]()
private var lookups = [AnyKeyPath : Set<Int>]()
```

`registerTracking` (willSet form; the didSet form is the same):

```swift
internal mutating func registerTracking(for properties: Set<AnyKeyPath>, willSet observer: @Sendable @escaping () -> Void) -> Int {
  let id = generateId()
  observations[id] = Observation(kind: .willSetTracking(observer), properties: properties)
  for keyPath in properties {
    lookups[keyPath, default: []].insert(id)
  }
  return id
}
```

`cancel`:

```swift
internal mutating func cancel(_ id: Int) {
  if let observation = observations.removeValue(forKey: id) {
    for keyPath in observation.properties {
      if var ids = lookups[keyPath] {
        ids.remove(id)
        if ids.count == 0 {
          lookups.removeValue(forKey: keyPath)
        } else {
          lookups[keyPath] = ids
        }
      }
    }
    observation.cancel()
  }
}
```

`willSet` (the `didSet` function has the same loop over `didSetTracker`):

```swift
internal mutating func willSet(keyPath: AnyKeyPath) -> [@Sendable () -> Void] {
  var trackers = [@Sendable () -> Void]()
  if let ids = lookups[keyPath] {
    for id in ids {
      if let tracker = observations[id]?.willSetTracker { trackers.append(tracker) }
    }
  }
  return trackers
}
```

`Context.willSet` takes the trackers inside the lock, then calls each one outside the lock.

T (`ObservationTracking`):

```swift
public static func _installTracking(_ list: _AccessList, onChange: @escaping @Sendable () -> Void) {
  let tracking = ObservationTracking(list)
  _installTracking(tracking, willSet: { _ in
    onChange()
    tracking.cancel()
  })
}
...
public func cancel() {
  let values = state.withCriticalRegion {
    $0.cancelled = true
    let values = $0.values
    $0.values = [:]
    return values
  }
  for (id, observationId) in values {
    switch observationId {
    case .willSet(let token): list.entries[id]?.removeObserver(token)
    case .didSet(let token):  list.entries[id]?.removeObserver(token)
    case .full(let w, let d): list.entries[id]?.removeObserver(w); list.entries[id]?.removeObserver(d)
    }
  }
}
```

The SPI `_installTracking(_ tracking:willSet:didSet:)` (used by SwiftUI) adds one willSet and/or didSet registration for each observed object, over all key paths that the tracking read. It adds no automatic cancel. The cancel in the `onChange:` overload is only for the public `withObservationTracking`.

### 1.2 Does `cancel` copy the Set? Yes, in 5.9 and 5.10

In `if var ids = lookups[keyPath] { ids.remove(id); ... }`, the local `ids` and the dictionary value share one buffer. The `remove` call must copy the buffer first (`_NativeSet.copy()`). This is O(n) for each removed id, for each key path of the tracking. This matches the tester's sample on macOS 14.6.

Inference: if n registrations stay in the set of one key path, and all n cancel, the total cost is O(n^2) in time, with a large allocation (`free_large`, `madvise`) for each copy. The code does not prove the build-up. It only proves the cost for a large set.

### 1.3 Swift 6.0, 6.1, 6.2 (tags swift-6.0-RELEASE, swift-6.1-RELEASE, swift-6.2-RELEASE)

`cancel` removes in place:

```swift
internal mutating func cancel(_ id: Int) {
  if let observation = observations.removeValue(forKey: id) {
    for keyPath in observation.properties {
      if let index = lookups.index(forKey: keyPath) {
        lookups.values[index].remove(id)
        if lookups.values[index].isEmpty {
          lookups.remove(at: index)
        }
      }
    }
    observation.cancel()   // 6.0 and 6.1 only
  }
}
```

Other changes against 5.9:

- 6.0 and 6.1: tracker closures take `(AnyKeyPath) -> Void`. `ObservationTracking.changed` is added (`@available(SwiftStdlib 6.0, *)`). `registerTracking` and `willSet` keep the same logic. `Context.willSet` calls `action(keyPath)`.
- 6.2: the computed and values observers are removed from `State`. `cancel` is the in-place form above (no `observation.cancel()`). `registerTracking`, `willSet`, `didSet` keep the same logic. `_installTracking` is as in 5.9, plus the `changed` store.

### 1.4 Which change fixed it

- Commit 54b3a9b64a, "[Observation] Optimize cancellation path to avoid excessive copies", PR #73288 by phausler. Opened 2024-04-26, merged to `main` 2024-04-30. PR body: "The existing code could potentially mis-optimize and create copies of the set for the cancellation tokens. This mutates it in-place to avoid those copies. Resolves: rdar://127018986".
- Cherry-pick to `release/6.0`: PR #73356, merged 2024-05-02 (commit e89eb31766).
- No cherry-pick to `release/5.10` was found. The `release/5.10` branch head still has `if var ids = lookups[keyPath]`.

### 1.5 Swift version for each macOS version

- Primary source for the library: the availability macros in `utils/availability-macros.def` (tag swift-6.2-RELEASE): `SwiftStdlib 5.9` = macOS 14.0; `5.10` = macOS 14.4; `6.0` = macOS 15.0; `6.1` = macOS 15.4; `6.2` = macOS 26.0. Observation is `@available(SwiftStdlib 5.9, *)` = macOS 14.0.
- Apple Xcode support table: Xcode 15.0 to 15.2 = compiler Swift 5.9 (macOS 14.0 to 14.2 SDK); Xcode 15.3 and 15.4 = Swift 5.10 (macOS 14.4, 14.5 SDK); Xcode 16 to 16.2 = Swift 6.0 (macOS 15.0 to 15.2 SDK); Xcode 16.3, 16.4 = Swift 6.1 (macOS 15.4, 15.5 SDK); Xcode 26 = Swift 6.2.
- Not confirmed: no source says which Swift commit the `libswiftObservation` in each macOS build uses. Apple builds from its own fork. The mapping above is the compiler version of the matching SDK, not the runtime build.
- Inference: macOS 14.0 to 14.6 carry Swift 5.9 or 5.10 Observation without the fix. The sample on 14.6 (`_NativeSet.copy()` in `cancel`) agrees. The fix was in `release/6.0` before the macOS 15 betas, so macOS 15.x (this dev Mac, 15.8.1) very likely has the in-place `cancel`. The sample from this Mac, or `otool` on the shared cache, would confirm it. Open question: sample or disassemble `State.cancel` on macOS 15.8.1 (not done, to keep the Mac idle).

## 2. Known reports of accumulating registrations

No Apple or Swift-team report of this exact case was found. The case: a view reads a property that never changes, re-renders often for another property, and keeps registrations until that property changes.

| Item | Link | Date | OS or Swift | Status |
|---|---|---|---|---|
| PR #73288, cancel copies Set | https://github.com/swiftlang/swift/pull/73288 | 2024-04-26 | Swift 5.9, 5.10 code | Owner: fixed in Swift 6.0 (see 1.4) |
| PR #82752, weakly held Observable leaves observation closures in memory (rdar://112167556, "a potential leak with SwiftUI") | https://github.com/swiftlang/swift/pull/82752 | 2025-07-02 | 6.2 branch | Owner. Different case (deinitialized objects). A revert (#83492, 2025-08-09) followed on the 6.2 branch; the `main` revert is #83436 (2025-10-06). It does not fix the case here |
| PR #85155, "Refine performance from metrics for observations' hotpaths" | https://github.com/swiftlang/swift/pull/85155 | 2025-10-27 | main | Owner. Open. Says profiles show hot sections "around cancellation" and set and dictionary lookup |
| Swift Forums pitch, "Observation performance and modeling improvements" | https://forums.swift.org/t/pitch-observation-performance-and-modeling-improvements/89924 | 2026-10-06 (as the page shows it) | New runtime | Pitch. Says re-registration costs 20 to 32 allocations for each write, and proposes a `Listener` where "registrations of objects no longer read are cancelled". Read through a page summary, so quotes are not checked against the raw page |
| Apple Developer Forums 736239, "@State ViewModel memory leak in iOS 17" | https://developer.apple.com/forums/thread/736239 | date not read | iOS 17 (from title) | Forum user. About model lifetime. Secondary. Not the same case. No Apple fix stated in what was read |
| Apple Developer Forums 816542, Charts redraw loops, 100 percent CPU | https://developer.apple.com/forums/thread/816542 | 2026-08 | not read in full | Forum user. Not the same case |
| LY Corp tech blog, "Observation in depth" | https://techblog.lycorp.co.jp/en/observation-in-depth | undated | OS not stated | Secondary. Says views must rebuild the access list after each evaluation and "If a property is observed by too many Views, the rebuild time will also significantly increase" |

Search of swiftlang/swift issues and PRs for "ObservationRegistrar", "withObservationTracking", "leak", and "State.cancel" found nothing that names the accumulation case. Search of Swift Forums and Apple Developer Forums also found none. The Medium article "Inspecting Swift's Observation" returned HTTP 403 and was not read.

## 3. Does SwiftUI cancel the old tracking when body runs again?

Primary facts:

- WWDC23 session 10149, "Discover Observation in SwiftUI" (Apple): "When body is executed, SwiftUI tracks all access to properties used from 'Observable' types." and "if say an order is added, the view won't be invalidated because that property isn't part of the tracked properties it determined when executing the body of the view." The session does not say when the old tracking ends.
- In the library (1.1), `_installTracking` with `willSet:` or `didSet:` has no automatic cancel. Only the caller (SwiftUI) can call `ObservationTracking.cancel()`.
- The sample shows `ObservationTracking.cancel()` called from a SwiftUI run loop observer in a graph update. This shows that SwiftUI cancels tracking in that phase. It does not show if the trigger is a property change or a new body run.
- No SwiftUI release note (iOS 17.x, iOS 18, macOS 14.x, macOS 15) about this was found. Only a web search ran for the iOS 18.1 notes; the search result summary lists no Observation item. Notes for the other releases were not read.

Inference: SwiftUI cancels the old tracking only when a tracked property fires (the library closure fires once) or when SwiftUI drops the view. If a body runs again for another reason (parent update, `@State`, environment) and SwiftUI does not cancel the old tracking, one more registration stays on every property the old body read. Properties that never change would never fire them, so the sets grow for 25 hours. Nothing public confirms or denies this. Probe to run when the lock allows: a view with one `@Observable` that has a constant property `q` and a fast property `p`; re-render the view by a parent `@State` change; count `lookups[q].count` through a debug build of a copy of the registrar, or watch heap growth.

Inference: the LY Corp text ("has to rebuild the access list and observation relationship after each re-evaluation") points to a new registration for each body run, but it is a secondary source.

## Claims that no source confirmed

1. That `libswiftObservation` on macOS 15.8.1 has the in-place `cancel` (very likely, not proven).
2. That SwiftUI leaves old registrations alive when body runs for another reason.
3. That the Swift Forums pitch text matches the raw page (page summary only).
4. The runtime Swift build of each macOS 14.x release (only SDK compiler versions and availability macros are primary).

## Sources

- https://github.com/swiftlang/swift/blob/swift-5.9-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift
- https://github.com/swiftlang/swift/blob/swift-5.10-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift
- https://github.com/swiftlang/swift/blob/swift-6.0-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift
- https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift
- https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift
- https://github.com/swiftlang/swift/blob/swift-5.9-RELEASE/stdlib/public/Observation/Sources/Observation/ObservationTracking.swift (and the same path at the 5.10, 6.0, 6.1, 6.2 tags)
- https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/utils/availability-macros.def
- https://github.com/swiftlang/swift/pull/73288 and commit 54b3a9b64a
- https://github.com/swiftlang/swift/pull/73356 (release/6.0 cherry-pick)
- https://github.com/swiftlang/swift/pull/82752
- https://github.com/swiftlang/swift/pull/85155
- https://developer.apple.com/support/xcode/
- https://developer.apple.com/videos/play/wwdc2023/10149/
- https://forums.swift.org/t/pitch-observation-performance-and-modeling-improvements/89924
- https://developer.apple.com/forums/thread/736239
- https://developer.apple.com/forums/thread/816542
- https://developer.apple.com/forums/tags/observation
- https://techblog.lycorp.co.jp/en/observation-in-depth
