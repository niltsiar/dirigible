# PAC mask for the frame-pointer walker on macOS arm64

Date: 2026-10-16

## 1. What KSCrash does

KSCrash strips PAC bits in `kscpu_normaliseInstructionPointer`.

- File: `Sources/KSCrashRecordingCore/KSCPU_arm64.c`, lines 146 to 168.
- Permalink: https://github.com/kstenerud/KSCrash/blob/230a1a05913e1b336cc06df9f4ea07933d78f572/Sources/KSCrashRecordingCore/KSCPU_arm64.c#L146-L168
- Commit 230a1a05 (2026-02-09, PR 764) is the last commit for this file. The file at master HEAD 8649e072 is the same.
- arm64e build (`__has_feature(ptrauth_calls)`): `ptrauth_strip((void *)ip, ptrauth_key_return_address)`.
- Plain arm64 build: `return ip & 0x00007FFFFFFFFFFFULL;` (47 bits).
- The code comment says: an arm64 binary that calls arm64e system libraries gets return addresses with PAC bits, and `ptrauth_strip` is a no-op on arm64.
- The callers apply it to each return address read from the stack: `KSStackCursor_Backtrace.c` line 41 and `Unwind/KSStackCursor_Unwind.c` line 602. They do not apply it to frame pointers.
- History: before PR 756 (commit a6b15f57), KSCrash used `KSPACStrippingMask_ARM64e 0x0000000fffffffff` (36 bits). Inference: this narrow mask can clip valid addresses above 64 GB. Do not copy it.

The current KSCrash value is `0x00007FFFFFFFFFFF`.

## 2. Is the mask correct for macOS arm64 user space?

Yes. The local SDK is macOS 26.2 (Xcode 26.3). Clang is 17.

- `mach/arm/vm_param.h` line 88: `MACH_VM_MAX_ADDRESS_RAW 0x00007FFFFE000000ULL`. The condition is the `#elif defined (__arm64__)` branch. The `__arm__` branch is separate. This SDK has no other definition.
- The highest user address, 0x00007FFFFE000000, is below 0x00007FFFFFFFFFFF. The 47-bit mask does not change a valid user address.
- XNU `osfmk/arm64/proc_reg.h` sets `T0SZ_BOOT` to 17 for 16 KB pages (47-bit VA) and to 25 with `__ARM64_PMAP_SUBPAGE_L1__` (39-bit VA). Inference: macOS uses the 17 case. No source names the macOS build option.
- `ptrauth.h` (clang 17) defines `ptrauth_strip` as `__builtin_ptrauth_strip` only when `__has_feature(ptrauth_intrinsics)`. In the other case (line 465), it is `({ (void)__key; __value; })`. It returns the value unchanged.
- `mach/arm/_structs.h`: a plain arm64 build has `__DARWIN_OPAQUE_ARM_THREAD_STATE64` equal to 0. The macros are plain field reads: `get_pc` is `((ts).__pc)` and `get_fp` is `((ts).__fp)`. They do not strip anything. `__darwin_arm_thread_state64_ptrauth_strip` is `(void)(ts)`.

## 3. Do signed return addresses reach a plain arm64 process?

Partly confirmed.

- Apple documents that arm64e return addresses are signed. It says "a crash reporting library that examines the stack contents needs to strip the PAC out of return addresses."
- The LLVM PointerAuthentication doc says tools that walk the frame chain must strip signatures, "if it is capturing a stack trace during a crash."
- The KSCrash comment and the PR 764 message say that frames from libdispatch and libsystem_kernel show as "(unknown)" in an arm64 binary without the mask.
- No primary source says this for macOS 14 and 15 by name. Inference: the claim holds there, because system libraries are arm64e on Apple silicon.
- No source confirms that a plain arm64 process sees signed saved LR values in frame records. The KSCrash comment is the only source. It is a library comment, not an Apple statement.
- The Mac of the run is Intel (`dyld_shared_cache_x86_64h`, macOS 15.8.1). It cannot show PAC bits, so the run has no probe.
- Open question for a probe on Apple silicon: print raw `fp[1]` for a thread that sits in `mach_msg2_trap`, and check the bits above bit 46.

## 4. Mask for the C function

Use `addr & 0x00007FFFFFFFFFFFULL`, under `#if defined(__arm64__)`. On x86_64, do not mask.

Tradeoff: the 47-bit mask is the same as the KSCrash value, and it leaves all valid user addresses unchanged. It clears PAC bits only if the user VA is 47 bits. A smaller VA would leave some PAC bits in bits 39 to 46. For macOS, XNU `T0SZ_BOOT` 17 and `MACH_VM_MAX_ADDRESS_RAW` support 47 bits.

Recommendation: use the KSCrash mask, apply it to pc, lr, and each `fp[1]`. Do not apply it to the chain pointer `fp[0]`. Inference: frame pointers are not signed. The walker must validate `fp[0]` as a pointer anyway. Add a comment that names `MACH_VM_MAX_ADDRESS_RAW`.

## Sources

- https://github.com/kstenerud/KSCrash/blob/230a1a05913e1b336cc06df9f4ea07933d78f572/Sources/KSCrashRecordingCore/KSCPU_arm64.c (code, comment, commit 230a1a05 message)
- https://github.com/kstenerud/KSCrash/blob/230a1a05913e1b336cc06df9f4ea07933d78f572/Sources/KSCrashRecordingCore/Unwind/KSStackCursor_Unwind.c and `KSStackCursor_Backtrace.c` (callers)
- https://github.com/kstenerud/KSCrash/commit/a6b15f576d00f0d673eab0f6618240df9a1dd7b9 (PR 756, old 36-bit mask)
- `MacOSX.sdk/usr/include/mach/arm/vm_param.h` (Xcode 26.3)
- `MacOSX.sdk/usr/include/mach/arm/_structs.h` (Xcode 26.3)
- `clang/17/include/ptrauth.h` of the Xcode toolchain (Xcode 26.3)
- https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/arm64/proc_reg.h (lines 1036 to 1070)
- https://developer.apple.com/documentation/security/preparing-your-app-to-work-with-pointer-authentication
- https://github.com/llvm/llvm-project/blob/main/clang/docs/PointerAuthentication.md (sections "Return addresses", `ptrauth_strip`)
