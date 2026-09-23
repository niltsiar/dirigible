# 0005. Dependency: apple/swift-atomics for the capture ring buffer

- Status: accepted
- Date: 2026-09-24

## Context

The IOProc of each device (0004) hands audio to its writer through a single-producer, single-consumer ring buffer. The real-time thread must not allocate, lock, or await, so the ring needs atomic loads and stores with acquire and release order.

The Swift `Synchronization` module (`Atomic`, `Mutex`) needs macOS 15. The SDK interface marks both `@available(macOS 15.0)`. Dirigible supports macOS 14 (R2).

## Decision

Use `apple/swift-atomics` (product `Atomics`) in `DirigibleAudio`. Allocate the ring storage and its `UnsafeAtomic` or `ManagedAtomic` indexes before capture starts. The IOProc only calls atomic loads and stores on them.

- License: Apache-2.0, the same as this repository. Apple maintains it.
- Version: `from: "1.2.0"`.
- Test the ring in a release build as well as a debug build. In a debug build, generic code that is not specialized can be slower on the real-time thread.
- When the minimum macOS version becomes 15, replace it with `Synchronization.Atomic` in one commit and remove the dependency.

## Consequences

- The package adds one dependency, fetched by SwiftPM at build time.
- `swift build` needs the network the first time, or a filled `.build` cache.

## Alternatives considered

- **A small C target with C11 `stdatomic.h`.** No dependency, about 60 lines. Rejected: Swift cannot see C11 `_Atomic` fields, so the target needs wrapper functions, and lock-free memory order in our own C code is easy to get wrong. swift-atomics is already tested and maintained.
- **`Synchronization.Atomic` on macOS 15 and a fallback on macOS 14.** Rejected: the fallback must work on both versions, so the second path adds nothing. Two paths double the tests, and `#available` ships both in the binary. The development Mac runs macOS 15, so the macOS 14 path would get less testing.
- **`ExtAudioFileWriteAsync` with no own ring.** Rejected in 0004: it lost audio on SIGKILL.
