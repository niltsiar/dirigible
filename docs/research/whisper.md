# Research: whisper.cpp in the Dirigible macOS app (F112)

Date: 2026-10-28

Run: `2026-10-28-whisper-in-app`. Target: SwiftPM package only (tools 6.2, Xcode 26.3, Swift 6.2.4), macOS 14 and later, universal release build (`scripts/bundle.sh` uses `--arch arm64 --arch x86_64`), ad-hoc signed DMG. The dev Mac is an Intel i5-8259U (4 cores, 8 threads), macOS 15.7.

How to read this file:

- Each finding has a number F1, F2, ... and a source URL or a local source path.
- "Inference:" marks a claim that no primary source states. Its basis follows it.
- "Source tree" means the tarball of tag v1.9.5 (`https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.5`). Paths such as `ggml/src/ggml-cpu/CMakeLists.txt` are paths in that tree. The same files are at `https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/<path>`.
- No build, no compile, and no compiler command ran for this file.

## Findings

State on 2026-11-24: the saved copies that this note names as `research/...` (`hf-tree.json`, `hf-model-readme.md`, `bench89.jsonl`, `papers/`, `apple/`, `spm/`, `clang/`, and `llvm/`) are not kept in the repo. Each finding names its source URL.

### Q1. Release, license, language standard, files, defines

**F1. Release and license.**
- The latest release is `v1.9.5`, published 2026-10-06. Its commit is `d1be6fde11ac6e0407606b4e42fe72d34add8037`. The release notes say "Updates to ggml v0.26.0". Source: `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5`, and `gh api repos/ggml-org/whisper.cpp/releases/latest`.
- The GitHub release v1.9.5 has no asset. A nightly tag `b5454` (same day, 2026-10-06) has the files, among them `whisper-b5454-xcframework.zip`. Source: `https://github.com/ggml-org/whisper.cpp/releases/tag/b5454`.
- The license is MIT. The file `LICENSE` says "MIT License, Copyright (c) 2023-2026 The ggml authors". The folder `ggml/` has no separate license file. So ggml inside whisper.cpp is under the same MIT text. Source: `LICENSE` of the source tree, `https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE`.
- One more notice sits in the CPU path: `ggml/src/ggml-cpu/llamafile/sgemm.cpp` has "Copyright 2024 Mozilla Foundation" with an MIT-style permission text. The default CMake build leaves `GGML_LLAMAFILE` off (F4), so a vendored build can skip that file. Source: file header, and `ggml/CMakeLists.txt` (`GGML_LLAMAFILE_DEFAULT OFF`).
- The tarball of `v1.9.5` has SHA-256 `ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720` (computed here from `https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.5`).
- Release cadence: v1.8.0 on 2025-09-30, v1.9.0 on 2026-06-17, v1.9.5 on 2026-10-06 (six releases in four months). Source: `gh api repos/ggml-org/whisper.cpp/releases`.

**F2. Language standard.**
- C11 and C++17. `ggml/CMakeLists.txt` sets `CMAKE_C_STANDARD 11` and `CMAKE_CXX_STANDARD 17`. `ggml/src/CMakeLists.txt` line 609 has `target_compile_features (${target} PRIVATE c_std_11 cxx_std_17) # don't bump`. The `whisper` target asks for `cxx_std_11` only (`src/CMakeLists.txt`).
- SwiftPM can state this with `cLanguageStandard: .c11` and `cxxLanguageStandard: .cxx17`. Inference: these two package-level settings exist in `PackageDescription`; they were not checked against the 6.2 manifest docs.

**F3. Source files for a CPU-only build on macOS.** Source: `ggml/src/CMakeLists.txt`, `ggml/src/ggml-cpu/CMakeLists.txt`, `src/CMakeLists.txt`.
- whisper: `src/whisper.cpp` (9367 lines), `src/whisper-arch.h`, `include/whisper.h` (772 lines). `src/aneforge/whisper-aneforge.cpp` is in the CMake list of target `whisper`. It builds a stub unless the build is `__APPLE__ && __aarch64__`; on arm64 it uses `dlopen` of a dylib named by the env var `ANEFORGE_DYLIB`. So it compiles in, and stays inactive without that variable.
- ggml-base (CMake target `ggml-base`): `ggml.c`, `ggml.cpp`, `ggml-alloc.c`, `ggml-backend.cpp`, `ggml-backend-meta.cpp`, `ggml-opt.cpp`, `ggml-threading.cpp`, `ggml-quants.c`, `gguf.cpp`, plus their headers.
- ggml (CMake target `ggml`, the backend registry): `ggml-backend-reg.cpp`, `ggml-backend-dl.cpp`.
- ggml-cpu (CMake target `ggml-cpu`): `ggml-cpu/ggml-cpu.c`, `ggml-cpu.cpp`, `repack.cpp`, `hbm.cpp`, `quants.c`, `traits.cpp`, `binary-ops.cpp`, `unary-ops.cpp`, `vec.cpp`, `ops.cpp`, `amx/amx.cpp`, `amx/mmq.cpp`, `tiled/tiled.cpp`, `tiled/tiled-kernel.cpp`, and per arch `arch/x86/quants.c`, `arch/x86/repack.cpp`, `arch/arm/quants.c`, `arch/arm/repack.cpp`. The `ggml-cpu/llamafile/sgemm.cpp` file is only in the list when `GGML_LLAMAFILE` is on (default off).
- Accelerate (BLAS backend): `ggml-blas/ggml-blas.cpp`, `include/ggml-blas.h`. On Apple, CMake sets `GGML_BLAS_DEFAULT ON` and `GGML_BLAS_VENDOR_DEFAULT "Apple"` (`ggml/CMakeLists.txt` lines 96-98). The BLAS backend takes `MUL_MAT` when `ne0`, `ne1`, and `ne10` are at least 32 (`ggml-blas.cpp`, `min_batch = 32`). It links the Accelerate framework.
- Size, counted here: the full list above is 73 files, 4.56 MB, 102,795 lines. That is 35 compile units (`.c` and `.cpp`, 3.88 MB, 88,299 lines) and 37 headers (0.65 MB). Without `llamafile`, `amx`, and `tiled` it is 62 files and 4.17 MB. For comparison, `Sources/CLame` is 45 files and 916 KB.
- Not needed for CPU only: `examples/`, `bindings/`, `models/`, `samples/`, `tests/`, `ggml-cuda`, `ggml-vulkan`, `ggml-sycl`, and the other backends. `src/coreml/`, `src/openvino/`, and `src/vitisai/` are optional.

**F4. Compile definitions that CMake sets on macOS.** Source: `ggml/src/CMakeLists.txt`, `ggml/src/ggml-cpu/CMakeLists.txt`, `ggml/src/ggml-blas/CMakeLists.txt`, `ggml/src/ggml-metal/CMakeLists.txt`, `CMakeLists.txt` line 215.

| Definition | Where CMake sets it | Needed by |
|---|---|---|
| `_XOPEN_SOURCE=600` | all targets, non-Linux | POSIX functions |
| `_DARWIN_C_SOURCE` | all targets, Darwin | `RLIMIT_MEMLOCK` and BSD extensions |
| `GGML_SCHED_MAX_COPIES=4` | all targets | optional, the source also defaults to 4 (`ggml-backend.cpp` line 911) |
| `GGML_USE_CPU` | target `ggml`, public | `ggml-backend-reg.cpp` registers the CPU backend only with it |
| `GGML_USE_BLAS` | target `ggml`, public, when BLAS is on | registers the Accelerate BLAS backend |
| `GGML_USE_METAL` | target `ggml`, public, when Metal is on | registers the Metal backend, and `whisper.cpp` line 1156 |
| `GGML_USE_ACCELERATE` | target `ggml-cpu`, with `ACCELERATE_NEW_LAPACK`, `ACCELERATE_LAPACK_ILP64` | vDSP use in `ggml-cpu` (`vec.h`, `binary-ops.cpp`, `ops.cpp`) |
| `GGML_BLAS_USE_ACCELERATE`, `ACCELERATE_NEW_LAPACK`, `ACCELERATE_LAPACK_ILP64` | target `ggml-blas` | `ggml-blas.cpp` |
| `GGML_USE_CPU_REPACK` | target `ggml-cpu`, default on | runtime weight repack |
| `GGML_METAL_EMBED_LIBRARY` | target `ggml-metal`, default follows `GGML_METAL` | embeds the shader (F10) |
| `GGML_METAL_NDEBUG` | only when `GGML_METAL_NDEBUG=ON` | removes Metal debug code |
| `WHISPER_VERSION="1.9.5"` | target `whisper`, private | `whisper_version()` (`whisper.cpp` line 9336) |
| `WHISPER_USE_COREML` | only when `WHISPER_COREML=ON` | Core ML encoder (F17) |

- CMake does not set `GGML_USE_CPU` as a define per backend file. It sets it on the registry target. A SwiftPM target that holds all files needs these defines in `cSettings` and `cxxSettings`.
- `ggml/src/ggml.c` line 4 includes `ggml-version.h`. CMake makes that header from `ggml-version.h.in` (`#define GGML_VERSION "@GGML_VERSION@"`, `#define GGML_COMMIT "@GGML_BUILD_COMMIT@"`). A vendored target must supply this header by hand. The ggml version in v1.9.5 is `0.26.0` (`ggml/CMakeLists.txt` lines 6-8).
- OpenMP is off for Apple clang (no OpenMP runtime). ggml then uses its own pthread thread pool.

**F5. The CPU architecture files collide in a universal build.**
- `arch/x86/quants.c` and `arch/arm/quants.c` both define `quantize_row_q8_0` and `ggml_vec_dot_q4_0_q8_0` at file level, and neither file has a top-level architecture guard (`arch/x86/quants.c` lines 302 and 701, `arch/arm/quants.c` lines 41 and 297). CMake adds only the file of the build architecture (`ggml-cpu/CMakeLists.txt`). `arch-fallback.h` renames the `_generic` functions per architecture.
- Inference: SwiftPM compiles each listed source for both slices of a universal build. So the two files would define the same symbol in one slice. A vendored target needs one wrapper `.c` file per architecture file, such as `#if defined(__x86_64__)` then `#include "arch/x86/quants.c"`, with the original files excluded. The same applies to `arch/*/repack.cpp`. Phase 4 must confirm this (Open question P3).

### Q2. SwiftPM, wrappers, and `.metal`

**F6. whisper.cpp ships no `Package.swift` today.**
- The root `Package.swift` and `Sources/whisper/module.modulemap` were removed in commit `5bb1d58c` (2025-03-13), "whisper: add xcframework build script (#2873)". The commit also removed `spm-headers/*` and added `build-xcframework.sh`. Source: `https://github.com/ggml-org/whisper.cpp/pull/2873`, `gh api repos/ggml-org/whisper.cpp/commits/5bb1d58c`.
- Reason, from the maintainer in issue #2869 "SPM Package broken": "Yes, I know it is broken. We need to do a similar solution as the one that was recently done in llama.cpp: https://github.com/ggml-org/llama.cpp/pull/11996. Basically, remove SPM support and start using XCFramework." Source: `https://github.com/ggml-org/whisper.cpp/issues/2869`.
- The README section "XCFramework" now shows a `.binaryTarget` with `url:` and `checksum:` (example for v1.7.5). Source: `README.md` of the source tree, lines 879-908.
- `ggml` has no `Package.swift` either (`ggml/` holds `CMakeLists.txt`, `cmake`, `include`, `src`).

**F7. How the known Swift wrappers build it.**
- `ggml-org/whisper.spm`: last push 2024-05-27, built a C target from copied sources, with `.unsafeFlags(["-Wno-shorten-64-to-32"])`. Its `Package.swift` comment says: "TODO: make Metal work - I can't figure out how to build ggml-metal.m", and it excludes `ggml-metal.m` and `ggml-metal.metal`. Source: `https://raw.githubusercontent.com/ggml-org/whisper.spm/master/Package.swift`.
- `exPHAT/SwiftWhisper`: last push 2024-05-23. Target `whisper_cpp` has only `.define` settings (`GGML_USE_ACCELERATE`, `WHISPER_USE_COREML`, `WHISPER_COREML_ALLOW_FALLBACK`) and `cxxLanguageStandard: .cxx11`. No `unsafeFlags`, no Metal. It vendors a whisper.cpp from before the ggml split. Source: `https://raw.githubusercontent.com/exPHAT/SwiftWhisper/master/Package.swift`.
- Official examples `whisper.swiftui` and `whisper.objc` use the XCFramework from `./build-xcframework.sh`, not a Swift package. Source: `examples/whisper.swiftui/README.md` lines 7-22 and `examples/whisper.objc/README.md` lines 14-16 of the source tree.
- Both Swift packages are stale, and both pre-date the 2024-2026 ggml. No maintained SwiftPM source package of v1.9.x was found.

**F8. The official XCFramework asset.**
- Versioned releases up to `v1.9.2` carry `whisper-v1.9.2-xcframework.zip` (53,575,921 bytes, SHA-256 `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b`). Releases `v1.9.3`, `v1.9.4`, and `v1.9.5` carry no asset. The nightly `b5454` carries `whisper-b5454-xcframework.zip` (65,816,082 bytes, SHA-256 `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b`). Source: `gh api repos/ggml-org/whisper.cpp/releases`.
- `build-xcframework.sh` builds the macOS slice with `CMAKE_OSX_ARCHITECTURES="arm64;x86_64"`, `MACOS_MIN_OS_VERSION=13.3`, `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`, `GGML_BLAS_DEFAULT=ON`, `GGML_NATIVE=OFF`, `GGML_OPENMP=OFF`, `WHISPER_COREML=ON`, and `-Wno-macro-redefined -Wno-shorten-64-to-32` in the C flags. Source: `build-xcframework.sh`.
- Inference: for the macOS slice `CMAKE_OSX_ARCHITECTURES` is the string `arm64;x86_64`. `ggml_get_system_arch()` (`ggml/cmake/common.cmake`) tests for exactly `arm64` or exactly `x86_64`, so this value gives `GGML_SYSTEM_ARCH=UNKNOWN`. The CPU CMake file then prints "Unknown CPU architecture. Falling back to generic implementations." and adds `-DGGML_CPU_GENERIC`. If so, the official universal slice uses generic quant kernels and no AVX flags on x86_64. No one checked this against the binary. Open question P6.
- A binary target pins a nightly tag today. Decision 0034 rejected "a prebuilt static library: a binary in git and a harder relink". A `.binaryTarget(url:checksum:)` keeps the binary out of git, but the relink problem stays.

**F9. SwiftPM and `.metal` files.**
- A SwiftPM clang target accepts these file types in one target: `c`, `m` (C and Objective-C), `mm`, `cc`, `cpp`, `cxx` (C++ and Objective-C++), and `s`, `S` (assembly, tools version 5 and later). Source: `Sources/PackageModel/SupportedLanguageExtension.swift` and `Sources/PackageLoading/TargetSourcesBuilder.swift` in `swiftlang/swift-package-manager` (saved in `research/spm/`).
- `.metal` is in `FileRuleDescription.xcbuildFileTypes` with the rule `.processResource(localization: .none)`, tools version 5.3. The comment says "File types related to Metal" and the list is "File types that requires the Xcode build system". So SwiftPM treats `.metal` as a resource. Only the Xcode build system (XCBuild or Swift Build) compiles it into `default.metallib`. The native `swift build` only copies the file.
- Inference: `scripts/bundle.sh` uses `--arch arm64 --arch x86_64`, which goes through the Xcode build system (`scripts/probe.sh` header says so). That path could compile `.metal` files. This was not tested. Open question P8.

**F10. How ggml loads the Metal shader.** Source: `ggml/src/ggml-metal/CMakeLists.txt`, `ggml/src/ggml-metal/ggml-metal-device.m`.
- Embed mode (`GGML_METAL_EMBED_LIBRARY`): CMake runs `cat` and `sed` on each of the 36 files in `kernels/*.metal`, glues `ggml-common.h` and `ggml-metal-impl.h` into them, and writes one assembly file per kernel with `.incbin "<absolute path>"` and the symbols `_ggml_metallib_<kind>_start` and `_end`. These `.s` files exist only at build time. A SwiftPM source target cannot reuse the CMake step as is. A vendoring script could write the glued `.metal` text once and commit it.
- Non-embed mode: `ggml_metal_find_metallib` looks for `default.metallib` as a bundle resource, then next to the running binary. The file `ggml-metal-device.m` has `#ifdef SWIFT_PACKAGE` / `NSBundle * bundle = SWIFTPM_MODULE_BUNDLE;` for the bundle. If no `default.metallib` exists, the code compiles the source with `newLibraryWithSource`, reading from the path in env var `GGML_METAL_PATH_RESOURCES` (lines 554-630). So upstream already has a SwiftPM hook.
- Metal sources: 8 `.cpp`/`.m` files (about 0.59 MB) plus 36 `.metal` files and 3 headers in `kernels/` (about 1.4 MB).
- On macOS 26 SDKs, CMake also builds a `ggml-tensor.metallib` (tensor API, needs OS 26). Without it the log says "disabling the tensor API".

### Q3. x86 SIMD and arm64

**F11. Where ggml tests the x86 features.** Source: the source tree.
- `ggml/src/ggml-cpu/ggml-cpu.c` line 3652: `#if defined(__AVX2__)` in `ggml_cpu_has_avx2`; line 3708: `#if defined(__FMA__)` in `ggml_cpu_has_fma`; line 3740: `#if defined(__F16C__)` in `ggml_cpu_has_f16c`. Lines 3482 and 3515: `#if defined(__F16C__)` in `ggml_cpu_fp32_to_fp16` and its inverse.
- `ggml/src/ggml-cpu/simd-mappings.h`: line 581 `#elif defined(__AVX__)` starts the 256-bit F32 path; line 595 `#if defined(__FMA__)` picks `_mm256_fmadd_ps`; line 644 `#if defined(__F16C__)` picks `_mm256_cvtph_ps`; line 900 `#elif defined(__SSE3__)` starts the 128-bit path; line 914 `#if defined(__FMA__)` again.
- `ggml/src/ggml-cpu/arch/x86/quants.c`: about 30 `#if defined(__AVX2__)` tests, for example lines 354, 450, 569, 718. The quantized dot products have an AVX2 path, an AVX path, and a generic path.
- All tests use the compiler macros. They do not test the `GGML_AVX2` names that CMake also defines.

**F12. CMake gets AVX2 only with `-m` flags.** Source: `ggml/src/ggml-cpu/CMakeLists.txt` lines 281-400.
- Default on macOS: `GGML_NATIVE` is ON (`ggml/CMakeLists.txt` line 106-109), which adds `-march=native`. With `GGML_NATIVE=OFF`, the options `GGML_SSE42`, `GGML_AVX`, `GGML_AVX2`, `GGML_BMI2`, `GGML_FMA`, `GGML_F16C` default to ON (`INS_ENB`), and CMake adds `-msse4.2 -mf16c -mfma -mbmi2 -mavx -mavx2`. The official XCFramework build uses `GGML_NATIVE=OFF`. So its x86_64 slice, if the flags apply (see F8), needs AVX2, FMA, and F16C.
- `GGML_CPU_ALL_VARIANTS` fails with "requires GGML_BACKEND_DL", and `GGML_BACKEND_DL` fails with "requires BUILD_SHARED_LIBS" (`ggml/src/CMakeLists.txt`). Dynamic backend loading builds shared module libraries. A static vendored SwiftPM target cannot use it.

**F13. Ways to get AVX2 without `unsafeFlags`.**
- Clang `__attribute__((target("avx2,fma,f16c")))` is documented: it "instructs the backend to use different code generation options than were passed on the command line". The attribute supports `#pragma clang attribute`. Function multiversioning with `target` and `target_clones` is documented only "for ELF based x86/x86-64 targets", so it does not work on Mach-O. Source: `https://clang.llvm.org/docs/AttributeReference.html` (target, target_clones), `https://clang.llvm.org/docs/LanguageExtensions.html` ("Specifying an attribute for multiple declarations (#pragma clang attribute)").
- Inference: the `target` attribute changes code generation but does not define `__AVX2__`, `__FMA__`, or `__F16C__`. ggml tests only those macros (F11). So a wrapper file would need to (1) `#pragma clang attribute push (__attribute__((target("avx2,fma,f16c"))), apply_to=function)`, and (2) define the three macros itself with `cSettings .define(...)` or in a header. It would also need a run-time check, for example `__builtin_cpu_supports("avx2")`, and a second compile of the CPU files for the SSE baseline. No source confirms this works. It is a large, fragile patch of vendored code. Open question P4.
- Inference: the x86_64h architecture. LLVM maps the Darwin architecture name `x86_64h` to the CPU `core-avx2` (`clang/lib/Driver/ToolChains/Arch/X86.cpp` lines 78-80 and 141). A fat binary with an `x86_64h` slice would give AVX2 with no `-m` flag in Package.swift. But SwiftPM would need an `x86_64h` triple on the command line. No source says SwiftPM or the Swift driver supports that. Open question P5.
- Baseline build, no `-m` flags: the clang default CPU for macOS x86_64 is `penryn` (`X86.cpp` lines 82-84: "macosx10.12 drops support for all pre-Penryn Macs"). Penryn has SSE3, SSSE3, and SSE4.1 but no AVX, FMA, or F16C. So `__SSE3__` is defined and ggml takes the 128-bit SSE branch (`simd-mappings.h` line 900). Source: `https://raw.githubusercontent.com/llvm/llvm-project/main/clang/lib/Driver/ToolChains/Arch/X86.cpp`. Without `__F16C__`, F16 weights convert with a lookup table or scalar code.
- Every Mac that macOS 14 supports has AVX2, FMA, and F16C. Inference: macOS 14 lists MacBook Pro/Air from 2018, iMac from 2019, Mac mini 2018, iMac Pro 2017, Mac Pro 2019 (`https://support.apple.com/en-us/105113`); those are Skylake or newer Intel parts, and Haswell (2013) introduced AVX2. Not confirmed per model.

**F14. Speed of the SSE-only baseline: no direct source.**
- No bench result of a no-AVX2 clang x86 Mac build was found. The nearest rows are confounded:
  - i7-1065G7, Windows 11, MSVC, "Config -": small.en encode 294,168 ms. After adding AVX2: 9,648.67 ms. That is 30 times, but MSVC defines no `__SSE3__`, so the first run was scalar. It is an upper bound, not the clang penryn case. Source: `https://github.com/ggml-org/whisper.cpp/issues/89#issuecomment-1309288832` and `#issuecomment-1309343627`.
  - Xeon E3-1220 V2 (Ivy Bridge: AVX, no AVX2/FMA/F16C), 4 threads, Linux: base 3,801 ms, small 14,545 ms. i7-8700 (AVX2), 4 threads: base 1,604 ms, small 5,631 ms. Ratio about 2.4 to 2.6, but the clocks differ. Source: `https://github.com/ggml-org/whisper.cpp/issues/89#issuecomment-1333701639`.
- The BLAS backend (Accelerate) takes the large encoder matrix products (rule `ne0, ne1, ne10 >= 32`, F3). Accelerate chooses its own SIMD at run time. So the baseline build loses less in the encoder than a pure ggml build. Inference: the loss is then in the decoder (matrix-vector products stay in `ggml-cpu`). Open question P2 measures it.

**F15. arm64.**
- NEON is always on for arm64. LLVM defaults the CPU of macOS arm64 to `apple-m1` (`clang/lib/Driver/ToolChains/Arch/AArch64.cpp` lines 28-33: "Apple Silicon macs default to M1 CPUs"). Source: `https://raw.githubusercontent.com/llvm/llvm-project/main/clang/lib/Driver/ToolChains/Arch/AArch64.cpp`.
- ggml tests `__ARM_NEON`, `__ARM_FEATURE_DOTPROD` (`arch/arm/quants.c` lines 840, 1417, 1461), `__ARM_FEATURE_MATMUL_INT8` (lines 302, 315), and `__ARM_FEATURE_FP16_VECTOR_ARITHMETIC` (`simd-mappings.h` line 263).
- Inference: the `apple-m1` CPU enables NEON, dot product, and FP16 vector arithmetic with no flag. It does not enable i8mm (`MATMUL_INT8`), which is an armv8.6 feature. The macro set of `apple-m1` was not read from the compiler. Open question P7.

### Q4. Metal and Core ML

**F16. Metal on Intel Macs.**
- The device init sets `has_simdgroup_mm = supportsFamily:MTLGPUFamilyApple7` (M1 and later), and `has_simdgroup_reduction = Apple7 || MTLGPUFamilyMetal3_GGML` (lines 1134-1138 of `ggml/src/ggml-metal/ggml-metal-device.m`). Code at lines 1267-1270 (`#if TARGET_OS_OSX && TARGET_CPU_X86_64`) sets shared buffers for an eGPU, so the code does treat Intel Macs as a target.
- `ggml_metal_supports_mul_mat_op` returns false when `has_simdgroup_reduction` is false (lines 1511-1519). Operations that the device does not support stay on the CPU through the ggml scheduler. A GPU with Metal 3 but not Apple7 still reports `has_simdgroup_reduction`. So Metal 3 Intel and AMD GPUs accept some operations.
- There is no CPU fallback for wrong results. `whisper_backend_init_gpu` takes the first device of type GPU or IGPU when `use_gpu` is true, with no family check (`src/whisper.cpp` lines 1301-1337). `whisper_context_default_params().use_gpu` is `true`.
- Reports of failure on Intel Macs, for the shared ggml Metal code:
  - llama.cpp issue 30702 (open, 2026-10-17): "Metal backend silently produces corrupted output on Intel Mac with AMD GPU (no error, no CPU fallback)"; the same binary with `-ngl 0` is correct. Source: `https://github.com/ggml-org/llama.cpp/issues/30702`.
  - llama.cpp issue 19563 (closed): "Metal backend produces garbage output on AMD discrete GPUs (Radeon Pro 5300M)".
  - llama.cpp issue 25866 (closed): a dispatch race on GCN/Vega GPUs gives corrupted output and "command buffer 0 failed with status 5".
  - llama.cpp issue 26949 (closed): an assert on Intel Mac with an AMD discrete GPU.
- No report for the Intel integrated GPU (UHD/Iris) in whisper.cpp was found. The README says only "Mac OS (Intel and Arm)" (README line 37).
- Inference: set `whisper_context_params.use_gpu = false` on x86_64. Basis: the reports above, `has_simdgroup_mm` false below Apple7, and the lack of an Intel iGPU report. The dev Mac has an Intel iGPU (Iris Plus 655 on the i5-8259U, not verified here). Open question P1.
- Apple silicon: the README says "On Apple Silicon, the inference runs fully on the GPU via Metal".

**F17. Core ML encoder.** Source: `README.md` section "Core ML support", `src/coreml/whisper-encoder.mm`, `models/generate-coreml-model.sh`, `models/convert-whisper-to-coreml.py`.
- Build flag: `-DWHISPER_COREML=1` (CMake) sets `WHISPER_USE_COREML`. It adds `src/coreml/*.m`, `*.mm` (Objective-C with ARC, `-fobjc-arc`) and links Foundation and CoreML. `-DWHISPER_COREML_ALLOW_FALLBACK=1` lets the run continue on the ggml encoder if the Core ML model fails to load; without it the state init fails.
- Model file: a folder `models/ggml-<model>-encoder.mlmodelc` next to `ggml-<model>.bin`. The path comes from the `.bin` path (`whisper_get_coreml_path_encoder`).
- How it is made: Python 3.11, `pip install ane_transformers openai-whisper coremltools`, then `./models/generate-coreml-model.sh <model>`. The script runs `convert-whisper-to-coreml.py --encoder-only True --optimize-ane True`, then `xcrun coremlc compile`. The README says Xcode and `xcode-select --install` are needed.
- Prebuilt encoders exist on Hugging Face: `ggml-base-encoder.mlmodelc.zip` 37,922,638 bytes, `ggml-small-encoder.mlmodelc.zip` 163,083,239, `ggml-medium-...` 567,829,413, `ggml-large-v3-turbo-encoder.mlmodelc.zip` 1,173,393,014. Source: `https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main`. The script `models/download-coreml-model.sh` is disabled: "this script hasn't been maintained and is not functional atm".
- Speed: the README says "more than x3 faster compared with CPU-only execution" on Apple silicon (ANE). The Core ML load runs `MLComputeUnitsAll` (`whisper-encoder.mm`). The README says the first run is slow because the ANE service compiles the model.
- Intel: no source states the behavior. Inference: the Neural Engine exists only on Apple silicon, so `MLComputeUnitsAll` on Intel uses CPU or GPU, with no gain claimed. Not tested.
- README line: "MacOS Sonoma (version 14) or newer is recommended, as older versions of MacOS might experience issues with transcription hallucination."
- A repeat-loop report on files over one hour with Core ML: issue 1851 "CoreML: Repeating parts of text instead of transcribing - more than an hour long files" (closed). Source: `https://github.com/ggml-org/whisper.cpp/issues/1851`.
- The README also lists "ANEForge" (an encoder on the ANE via a research dylib, env vars `ANEFORGE_ENCODER` and `ANEFORGE_DYLIB`). It needs a Python export per machine and OS build. Not suited for a shipped app.

### Q5. Models

**F18. Model files.** Source: `https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main` (saved as `research/hf-tree.json`); `https://huggingface.co/ggerganov/whisper.cpp/raw/main/README.md` (SHA-1 column); `models/README.md`. The repo head is `5359861c739e955e79d9a303bcbc70fb988958b1` (last modified 2024-10-29), so the files are stable. A pinned URL is `https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin`.

- The SHA-256 column is the Hugging Face LFS `oid` (SHA-256 of the file). The SHA-1 column is the one in the model README of whisper.cpp and Hugging Face; it is a 40-hex string and is not a SHA-256.
- The quantized names are not uniform. `tiny`, `base`, and `small` have `-q5_1` and `-q8_0`. `medium` and the large models have `-q5_0` and `-q8_0`. No `base-q5_0` or `small-q5_0` file exists in the Hugging Face tree.

| Model | Bytes | Size | SHA-256 (HF LFS oid) | SHA-1 (README) |
|---|---|---|---|---|
| tiny | 77,691,713 | 74.1 MiB | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` | `bd577a113a864445d4c299885e0cb97d4ba92b5f` |
| tiny-q5_1 | 32,152,673 | 30.7 MiB | `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7` | `2827a03e495b1ed3048ef28a6a4620537db4ee51` |
| tiny-q8_0 | 43,537,433 | 41.5 MiB | `c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca` | `19e8118f6652a650569f5a949d962154e01571d9` |
| base | 147,951,465 | 141.1 MiB | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | `465707469ff3a37a2b9b8d8f89f2f99de7299dac` |
| base-q5_1 | 59,707,625 | 56.9 MiB | `422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898` | `a3733eda680ef76256db5fc5dd9de8629e62c5e7` |
| base-q8_0 | 81,768,585 | 78.0 MiB | `c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9` | `7bb89bb49ed6955013b166f1b6a6c04584a20fbe` |
| small | 487,601,967 | 465.0 MiB | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | `55356645c2b361a969dfd0ef2c5a50d530afd8d5` |
| small-q5_1 | 190,085,487 | 181.3 MiB | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` | `6fe57ddcfdd1c6b07cdcc73aaf620810ce5fc771` |
| small-q8_0 | 264,464,607 | 252.2 MiB | `49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f` | `bcad8a2083f4e53d648d586b7dbc0cd673d8afad` |
| medium | 1,533,763,059 | 1.43 GiB | `6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208` | `fd9727b6e1217c2f614f9b698455c4ffd82463b4` |
| medium-q5_0 | 539,212,467 | 514.2 MiB | `19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f` | `7718d4c1ec62ca96998f058114db98236937490e` |
| medium-q8_0 | 823,369,779 | 785.2 MiB | `42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502` | `e66645948aff4bebbec71b3485c576f3d63af5d6` |
| large-v3 | 3,095,033,483 | 2.88 GiB | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` | `ad82bf6a9043ceed055076d0fd39f5f186ff8062` |
| large-v3-q5_0 | 1,081,140,203 | 1.01 GiB | `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1` | `e6e2ed78495d403bef4b7cff42ef4aaadcfea8de` |
| large-v3-turbo | 1,624,555,275 | 1.51 GiB | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` | `4af2b29d7ec73d781377bfd1758ca957a807e941` |
| large-v3-turbo-q5_0 | 574,041,195 | 547.4 MiB | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | `e050f7970618a659205450ad97eb95a18d69c9ee` |
| large-v3-turbo-q8_0 | 874,188,075 | 833.7 MiB | `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1` | `01bf15bedffe9f39d65c1b6ff9b687ea91f59e0e` |
| base.en | 147,964,211 | 141.1 MiB | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` | `137c40403d78fd54d454da0f9bd998f78703390c` |
| small.en | 487,614,201 | 465.0 MiB | `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d` | `db8a495a91d927739e50b3fc1cc4c6b8f6c2d022` |

- Multilingual versus English only: "Models are multilingual unless the model name includes `.en`" (`models/README.md`). `.en` models cannot transcribe Spanish. Large-v3 and large-v3-turbo have no `.en` file.
- Weights license: the Hugging Face model card header says `license: mit` (`https://huggingface.co/ggerganov/whisper.cpp`). The upstream OpenAI models `openai/whisper-large-v3-turbo` also say `license: mit`, and the `openai/whisper` repo license is MIT (`gh api repos/openai/whisper`).
- The VAD model: `ggml-org/whisper-vad` on Hugging Face (`license: mit`) holds `ggml-silero-v6.2.0.bin` (885,098 bytes, SHA-256 `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`) and `ggml-silero-v5.1.2.bin` (885,098 bytes, SHA-256 `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`). Revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b`. Silero VAD itself is MIT (`gh api repos/snakers4/silero-vad`).

**F19. Memory.** The README table "Memory usage": tiny 75 MiB disk / ~273 MB memory; base 142 MiB / ~388 MB; small 466 MiB / ~852 MB; medium 1.5 GiB / ~2.1 GB; large 2.9 GiB / ~3.9 GB (`README.md` lines 136-144). The table has no row for large-v3-turbo or for quantized files. Inference: a quantized file needs about its file size plus the same working buffers, so turbo-q5_0 would need about 1 GB. Not measured. Open question P9.

### Q6. Speed

**F20. Benchmark data.** Source: `https://github.com/ggml-org/whisper.cpp/issues/89` ("Benchmark results", 187 comments; saved in `research/bench89.jsonl`). The tool `bench` times the encoder for one 30 s window ("Enc.", in ms). The release notes of v1.7.6 list "Dec." as the time of one single-token decode step in ms.

Intel rows (encoder ms per 30 s window, 4 threads):

| CPU | OS and config | tiny | base | small | medium | large | Date, source |
|---|---|---|---|---|---|---|---|
| i7-8750H (6 cores, 12 threads) | macOS 13.0.1, AVX2 BLAS (Accelerate) | 571 | 1,184 | 4,157 | 13,072 | 36,384 | 2022-12, comment 1333701639 |
| i7-8750H, 8 threads | same | 487 | 1,114 | 3,955 | 13,076 | 25,562 | same |
| i7-8700 (6 cores) | Ubuntu, AVX2 | 731 | 1,604 | 5,631 | 18,749 | 37,188 | same comment |
| i7-8650U (4 cores, 8 threads, Docker) | Ubuntu 22.04, AVX2, no BLAS, commit c7b6988 | 2,351 | 5,259 | 22,800 | 62,714 | not run | 2024-09, comment 2381009440 |
| i9-9900K, 4 threads | macOS 12.6.2, AVX2 BLAS | 360 (tiny.en) | 736 (base.en) | 2,400 (small.en) | 6,860 (medium.en) | not run | 2022-12, comment 1363914983 |

- The i7-8750H row is the closest to the dev Mac: same Coffee Lake family, same OS, Accelerate. Its CPU has 6 cores, the i5-8259U has 4, and the bench used 4 threads. The i7-8650U row (15 W laptop part) shows how much a thermally limited 4-core part can lose: 4 to 5 times slower than the 8750H on the same models. Both rows are old ggml code (2022 and 2024). The current default flash attention (since v1.8.0, F23) and other changes may shift the numbers. The speed of the i5-8259U (28 W class) is between the two rows. (Clock and TDP of the i5-8259U are from memory, not verified.)
- Apple silicon, from the v1.7.6 release notes (M2 Ultra, Metal, flash attention on, 1 thread, ms): tiny Enc 7.72, base 13.52, small 38.78, medium 104.48, large-v2 189.82, large-v3-turbo 170.22 (Dec 1.46 per token), large-v3-turbo-q5_0 201.88 (Dec 1.27). Source: `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.7.6` (saved in `research/rel-v1.7.6.md`).
- Apple silicon CPU only (M1 Pro, macOS 13.0.1, NEON BLAS, 8 threads): tiny 102, base 220, small 685, medium 1,928, large 3,350 ms. Source: issue 89 body.

**F21. Real-time factor for 1 h of audio on a 4-core Intel CPU.** All values are Inference. Basis: 1 h is 120 windows of 30 s (`WHISPER_CHUNK_SIZE 30` in `whisper.h`, `seek` moves about 30 s per window); time = 120 x encoder time; the decoder time is not included. The decoder adds time for the roughly 100 tokens per window. RTF is processing time divided by audio time.

| Model | Encoder per window (Intel, 2 rows above) | Encoder only for 1 h | RTF (encoder only) |
|---|---|---|---|
| base (141 MiB) | 1.2 s to 5.3 s | 2.4 min to 10.5 min | 0.04 to 0.18 |
| small (465 MiB; small-q5_1 181 MiB) | 4.2 s to 22.8 s | 8.3 min to 45.6 min | 0.14 to 0.76 |
| large-v3-turbo, and turbo-q5_0 | at least 36 s (the encoder of turbo is the large-v3 encoder; row "large", 8750H) | at least 73 min | at least 1.2 |

- Inference: large-v3-turbo has the large-v3 encoder (32 layers) and a 4-layer decoder (F31). No Intel number for turbo exists. The `large` row is the proxy. On a 45 W 6-core part the encoder alone is already slower than real time. So turbo, with or without q5_0, is not viable on the CPU path of the dev Mac. q5_0 reduces file size, not encoder time: in the 8550U matrix test, Q5_0 matrix products ran at 48 to 66 GFLOPS against 38 to 65 for F16 (comment 1553131445), and the BLAS path dequantizes to F32 first.
- Inference: with Metal on Apple silicon, turbo needs about 0.17 s encoder plus about 100 tokens x 1.5 ms per window (M2 Ultra), so about 0.35 s per window, about 42 s for 1 h (RTF 0.012). A base M1 is slower; no row for it in the current data.
- Threads: `whisper_full_default_params` sets `n_threads = min(4, hardware_concurrency)` (`src/whisper.cpp` line 6093). On the 8750H, 8 threads gave 4 to 30 percent less time than 4 threads (rows above). So hyper-threads give little.

### Q7. Word timestamps

**F22. Token-level timestamps (heuristic).** Source: `include/whisper.h`, `src/whisper.cpp` lines 8784-8900.
- `whisper_full_params.token_timestamps` (default false), `thold_pt` (0.01), `thold_ptsum` (0.01), `max_len` (segment length limit in characters, 0 = off), `split_on_word` (default false), `max_tokens` (0 = no limit). The header marks them "[EXPERIMENTAL]".
- Method: the decoder's timestamp-token probabilities place token starts when `pt > thold_pt && ptsum > thold_ptsum`. Tokens without a hit get time shared by "voice length" (`voice_length(text)`, a text heuristic). This is not an alignment on the audio. Times are in centiseconds in `whisper_token_data.t0` and `t1`.
- `max_len` with `split_on_word = true` splits segments at tokens whose text starts with a space (`should_split_on_word`: `txt[0] == ' '`). So `max_len = 1` and `split_on_word = true` gives one segment per word (this is what the CLI flag `-ml 1` does).
- Maintainer view on timing accuracy: issue 2812 ("Accurate 'sentence' timings"), the maintainer says the gap problem "Likely requires to apply VAD to the raw audio before feeding it to Whisper" (2025-03-31). Source: `https://github.com/ggml-org/whisper.cpp/issues/2812`.

**F23. DTW token timestamps.** Source: `include/whisper.h`, `src/whisper.cpp` lines 3817-3819, 7910-7920, 9166-9330; PRs 1485, 3612, 3704.
- Enable with `whisper_context_params.dtw_token_timestamps = true` and `dtw_aheads_preset` set to the model, for example `WHISPER_AHEADS_BASE`, `WHISPER_AHEADS_SMALL`, `WHISPER_AHEADS_LARGE_V3_TURBO` (the enum has presets from tiny to large-v3-turbo, `.en` variants included). The CLI flag is `-dtw <model>`.
- Trap: `flash_attn` defaults to `true` (`whisper_context_default_params`; v1.8.0 notes: "Flash attention is now enabled by default"). `whisper_init_with_params_no_state` then disables DTW silently: "dtw_token_timestamps is not supported with flash_attn - disabling" (line 3817). An app that wants DTW must set `flash_attn = false`. PR 3704 (open, 2026-03-11) would lift this. Slower attention is the price.
- Output: `whisper_token_data.t_dtw` in centiseconds, "Roughly corresponds to the moment in audio in which the token was output" (header comment). It is a start time only. PR 3612 (open, 2026-01-19) would add `t_dtw_end`, because "silence [is] absorbed into token durations, making pause detection impossible".
- Status: the header marks it "[EXPERIMENTAL]". The code has a comment `FIXME: will timestamp offsets be correct?` (line 7907).
- Inference (code reading): in the DTW branch, `new_segment_callback` runs in `for (int seg = (int) result_all.size() - n_segments; seg < n_segments; seg++)` (line 7915). After the first window `result_all.size() - n_segments` is not below `n_segments`, so the loop may not run. The callback would then not fire for later windows when DTW is on. Not tested. Open question P10.
- `whisper_exp_compute_token_level_timestamps_dtw` uses `params.language` to find the language id. Inference: with `language = "auto"`, `whisper_full_with_state` sets `params.language` to the detected code before this point (line 7011), so it should work. Not tested.

**F24. JSON full output (`-ojf`).** Source: `examples/cli/cli.cpp` lines 624-810.
- File fields: `systeminfo`, `model` (type, multilingual, vocab, audio, text, mels, ftype), `params`, `result.language`, `transcription[]`.
- Each `transcription[]` item: `timestamps.from` and `timestamps.to` (strings), `offsets.from` and `offsets.to` (integers, ms: the code writes `t0 * 10`), `text`. With `-ojf` each item also has `tokens[]`.
- Each token: `text`, `timestamps` and `offsets` (only when the token has `t0 > -1 && t1 > -1`), `id`, `p` (probability), `t_dtw` (centiseconds, -1 when DTW is off). `-ojf` sets `wparams.token_timestamps = true`. Special tokens (`[_BEG_]`, `[_TT_*]`) appear in `tokens[]`.
- The CLI merges tokens that split one UTF-8 character. A caller of the C API must do the same (see F25).

**F25. How a word is made from tokens.**
- whisper.h has no word-level API. The caller reads `whisper_full_n_tokens`, `whisper_full_get_token_data` (id, p, t0, t1, t_dtw), and `whisper_full_get_token_text` / `whisper_token_to_str`, and joins tokens.
- Rule: a token whose text starts with a space begins a new word (this is the rule `should_split_on_word` uses). A token with no leading space continues the previous word (word parts, punctuation, and bytes of a split multi-byte character). Special tokens have id `>= whisper_token_eot(ctx)`; the CLI skips them (`tokens[j].id >= whisper_token_eot(ctx)`).
- Multi-byte characters can be split over tokens; the CLI merges tokens until the UTF-8 is complete (`utf8_trailing_bytes_needed`, comment "Refs issue #1798").
- With VAD on, `whisper_full_get_token_t0` / `t1` return times mapped back to the original timeline, while `whisper_full_get_token_data().t0/t1` stay in VAD-processed time (comment in `whisper.h`). Use the first pair with VAD.
- Inference: a word start from the first token and a word end from the last token's `t1` follows from the above; no source gives this exact recipe.

### Q8. C API for an app

**F26. Calls and params.** Source: `include/whisper.h`, `src/whisper.cpp` lines 3713, 6089.
- Init: `whisper_init_from_file_with_params(path, whisper_context_params)`. Returns NULL on failure. Free with `whisper_free(ctx)`. Defaults of `whisper_context_params`: `use_gpu = true`, `flash_attn = true`, `gpu_device = 0`, `dtw_token_timestamps = false`.
- Run: `whisper_full(ctx, whisper_full_params, const float * samples, int n_samples)` returns 0 on success. Get strategy params with `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)` (greedy `best_of` 5) or `BEAM_SEARCH` (beam 5).
- Defaults of `whisper_full_params`: `n_threads = min(4, hardware_concurrency)`, `language = "en"` (not auto), `detect_language = false`, `translate = false`, `no_context = true`, `print_progress = true` (set false in an app: it prints to stderr), `print_timestamps = true`, `suppress_blank = true`, `suppress_nst = false`, `temperature = 0`, `temperature_inc = 0.2`, `entropy_thold = 2.4`, `logprob_thold = -1.0`, `no_speech_thold = 0.6`, `vad = false`. `initial_prompt` is a `const char *`.
- Language: `language = "auto"` (or NULL or "") turns on auto detection (`whisper_full_with_state` line 6993). The detected code is in `whisper_lang_str(whisper_full_lang_id(ctx))`. `whisper_lang_max_id()` gives the language count. `whisper_is_multilingual(ctx)` tells whether the model is multilingual.
- Callbacks (all `void *` user data):
  - `progress_callback(ctx, state, int progress, user_data)` runs at the start of each 30 s window loop turn, with `progress` as an integer percent (lines 7195-7199). It does not run while a window encodes. So the update rate is one per window (about 1 per 2 to 20 s of work on the CPU path).
  - `new_segment_callback(ctx, state, int n_new, user_data)` runs for each new batch of segments. Read them with the `whisper_full_*` functions. (See F23 for a DTW case.)
  - `abort_callback` (type `ggml_abort_callback`, `bool (*)(void *)`): when it returns true, the encode or decode graph stops; `whisper_full` returns -6 (encode) or -7 or -8 (decode); lines 7217, 7331, 7343. It is checked inside `ggml` graph computation (`whisper_encode_internal`, `whisper_decode_internal`), so a cancel takes effect in the current graph compute, not at the next window.
  - `encoder_begin_callback`: return false to abort before the encoder starts.
- `whisper_log_set(callback, user_data)` redirects the default stderr log.

**F27. Threads and input.**
- Header comment: "The following interface is thread-safe as long as the sample whisper_context is not used by multiple threads concurrently." `whisper_full`: "Not thread safe for same context". For parallel work, use `whisper_init_state` (one `whisper_state` per thread) with `whisper_full_with_state`.
- Input: 16 kHz, mono, 32-bit float PCM in the range -1 to 1 (`WHISPER_SAMPLE_RATE 16000`; the header example says "pcmf32 contains the RAW audio data in 32-bit floating point format"). `n_samples` is an `int`, so the limit is 2^31 samples, about 37 h.
- Long audio: `whisper_full` computes the log-mel spectrogram for the whole input first (`whisper_pcm_to_mel_with_state` at the start of `whisper_full_with_state`), then runs 30 s windows with a moving `seek` offset, and an input of any length is accepted. Inference: the mel buffer for 1 h is 80 bins x 360,000 frames x 4 bytes = 115 MB, plus the 230 MB input at 16 kHz float. Not measured.
- Auto language detection uses the first window only: `whisper_lang_auto_detect_internal(ctx, state, 0, ...)` (offset 0). A file that changes language gets the language of its first 30 s. MacWhisper documents the same limit as a topic: "Multiple languages in a file" (`https://docs.macwhisper.com/article/23-multiple-languages-in-a-file`; title seen, text not read).
- `offset_ms` and `duration_ms` in the params restrict the range.

**F28. VAD.**
- Added in release `v1.7.6` (2025-06-25): "Add initial VAD support - feedback welcome and appreciated". Source: `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.7.6`. v1.8.1 notes: "Fix memory leaks when using VAD".
- Model: Silero VAD in ggml format, `ggml-silero-v6.2.0.bin` (or `v5.1.2`), 885,098 bytes, from `https://huggingface.co/ggml-org/whisper-vad` (F18). Script: `models/download-vad-model.sh silero-v6.2.0`.
- API: `whisper_full_params.vad = true`, `vad_model_path`, and `vad_params` (`threshold` 0.5, `min_speech_duration_ms` 250, `min_silence_duration_ms` 100, `max_speech_duration_s` FLT_MAX, `speech_pad_ms` 30, `samples_overlap` 0.1). The VAD model runs on the CPU only inside `whisper_full` (`whisper.cpp` line 4819: `use_gpu = false`). Extra calls: `whisper_vad_*`, `whisper_full_n_vad_segments`.
- Effect (README): the VAD "passes only the speech segments that are detected" and "can significantly speed up the transcription process". The code maps times back to the original timeline through `vad_mapping_table`, so segment and token times (with the `get_token_t0` calls, F25) are in the original timeline. `whisper_full_n_vad_segments` returns the speech spans.

**F29. Hallucination and repeat loops, and the mitigations.**
- Open reports: issue 1724 "Hallucination on silence" (open, 28 comments; silence at the end of a file gives made-up text); issue 1507 "Whisper large v3 model repeats a lot" (open); issue 3278 (loop without VAD); issue 3744 "Proposal: reduce repetition hallucinations in long-form decoding" (open); issue 3729 (sentence repeated for long recordings).
- The maintainer on 1507 (2023-11-17): the repeats look like a model issue ("my analysis indicate that the problem is in the v3 model itself"); strategies that "reduce repetition and hallucinations": use 5 beams; raise `entropy_thold` from 2.4 to for example 2.8 ("Higher threshold will reject repetitive text and fallback to sampling with higher temperature"); reduce `--max-context` ("Setting it to 0 will most likely eliminate all repetitions, but the transcription quality can be affected"). Source: `https://github.com/ggml-org/whisper.cpp/issues/1507`. In the C API the context is `n_max_text_ctx`, and the default `no_context = true` already drops the previous text.
- `no_speech_thold` (0.6) is a conjunction. A segment is dropped as no speech only when `no_speech_prob > no_speech_thold` AND `avg_logprobs < logprob_thold` (-1.0): `src/whisper.cpp` line 7780. The fallback test on the same value uses the two together too (line 7750). So raising `no_speech_thold` alone does not remove a confident hallucination.
- `entropy_thold` (2.4) triggers a re-decode at a higher temperature (`temperature_inc` 0.2) when the text is repetitive (line 7722, `result_len > 32 && entropy < entropy_thold`).
- `suppress_nst = true` suppresses non-speech tokens (a fixed list: quotes, brackets, music notes; `non_speech_tokens` in `whisper.cpp`). Default is false.
- VAD (F28) removes the silence that triggers most hallucinations. The maintainer's view on issue 2812: VAD before Whisper.
- Report on Core ML and files longer than one hour: issue 1851 (F17).

### Q9. Languages and accuracy

**F30. Spanish and English WER from the Whisper paper.** Source: Radford et al., "Robust Speech Recognition via Large-Scale Weak Supervision", arXiv 2212.04356, Appendix D.2 (read from `https://ar5iv.labs.arxiv.org/html/2212.04356`, saved in `research/papers/`). Tables have the caption after the table. WER in percent, greedy decoding of the original models (the models of the ggml files are conversions of these).

| Dataset (paper table) | tiny | base | small | medium | large | large-v2 |
|---|---|---|---|---|---|---|
| Spanish, Fleurs (Table 13) | 15.9 | 9.9 | 5.6 | 3.6 | 3.5 | 3.0 |
| Spanish, Common Voice 9 (Table 11) | 30.3 | 19.6 | 10.3 | 6.9 | 6.4 | 5.6 |
| Spanish, MLS (Table 10) | 19.2 | 12.8 | 7.8 | 5.3 | 5.4 | 4.2 |
| Spanish, VoxPopuli (Table 12) | 19.7 | 14.4 | 11.1 | 9.6 | 8.8 | 8.2 |
| English, Fleurs (Table 13) | 12.4 | 8.9 | 6.1 | 4.4 | 4.5 | 4.2 |
| English, Common Voice 5.1 (Table 8, multilingual models) | 29.6 | 21.6 | 13.5 | 10.3 | 9.5 | 9.0 |

- Auto language detection: yes (F26), from the first 30 s.
- `.en` models: English only (F18).
- No WER of the quantized ggml files was found. Inference: q5 and q8 loses a little accuracy; the size is unknown without a test. Open question P11.

**F31. Does large-v3-turbo keep Spanish quality?**
- Facts: turbo is large-v3 with the decoder cut from 32 to 4 layers, then fine-tuned; 809 M parameters against 1550 M. The OpenAI maintainer: "Across languages, the turbo model performs similarly to large-v2, though it shows larger degradation on some languages like Thai and Cantonese", and "Whisper turbo performs better on FLEURS, which consists of cleaner recordings than Common Voice". Source: `https://github.com/openai/whisper/discussions/2363`, `https://huggingface.co/openai/whisper-large-v3-turbo` (model card).
- Large-v3: "10% to 20% reduction of errors compared to large-v2 across a wide variety of languages" (`https://huggingface.co/openai/whisper-large-v3`).
- The sources give no Spanish number for turbo (the chart in the discussion is an image). Inference: Spanish is not one of the named degraded languages, so turbo is near large-v2 (Fleurs 3.0, Common Voice 5.6). Not confirmed.

### Q10. Reference apps

**F32. Hindenburg PRO 2.** Sources: `https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2700/` (release 2.05), `https://hindenburg.com/products/radio-podcast/features/transcription/`.
- On-device or cloud: the feature page says "the transcription engine works inside your computer without sending your data to a third-party server" and "Even without an internet connection, you can work from any corner of the world". It also tracks "transcription hours": "the software keeps track and lets you know when you're running low", and you "hop back online to refill your hours". So the processing is local, and the use is metered (licensing, not stated how).
- Engine: "secure offline transcription engine". No engine name on either page. Inference: not stated; the "Small" and "Large" model names fit a Whisper-class engine, but no source says so.
- Languages: 99 languages since 2.05 (before: 13), with right-to-left display. Two models in the "Transcription settings" of the app: "Small": "Optimized for the major languages (English, Spanish, French, German, etc.), faster and lighter"; "Large": "Recommended for less common languages... more comprehensive language coverage but requires slightly more resources".
- Command: top menu "Tools / Transcribe", then "Open Transcription"; the "Manuscript view" opens from the navigation menu. The user picks the language: "select the language spoken in the recording to get the correct result".
- Model download: not described on either page. Progress: not described. Speed warning: "on older or less powerful machines, transcription may run slowly - or not at all".

**F33. Descript.** Source: `https://help.descript.com/hc/en-us/articles/10249408168845`.
- Languages: the page says 26, and its table lists 27 entries, including Spanish (US), French, German, Italian, Brazilian Portuguese, and Hindi (Beta). One language per file. Auto language detection works except for English (UK) and Welsh. Language choice: App settings has a preferred transcription language or "Always ask before transcribing"; fix a wrong language with Project > Files > the ellipsis menu > Re-transcribe.
- Cloud or local: the page does not say. Not confirmed by a source here. Inference: Descript is an account-based product; the claim "cloud" was not read in a primary page.

**F34. Final Cut Pro.** Source: `https://support.apple.com/guide/final-cut-pro/vere399dab5e/mac` (guide for Final Cut Pro 12.4).
- The guide names the feature "Generate Captions". Quote: "The Generate Captions feature requires a Mac with Apple silicon and is available in U.S. English only." So it is Apple silicon only, U.S. English only. The guide gives no macOS number in the text read.
- Command: select clips in the timeline, then Edit > Generate Captions > Closed Captions (Shift-Command-C), or the Control-click menu, or the Enhancements pop-up menu below the viewer.
- Model download: "If you're creating captions automatically for the first time, Final Cut Pro downloads the language model and then creates the captions. The download happens only once (an internet connection is required)." Progress: not described in the text read. On-device: not stated in the text read.
- The older name "Transcribe to Captions" was not found in the current guide. Not confirmed.

**F35. Logic Pro.** Source: `https://support.apple.com/en-us/109503` (release notes, latest 12.4) and `https://support.apple.com/guide/logicpro/whats-new-in-logic-pro-lgcp4a62a494/mac`.
- The release notes page, read through a text summary, has no mention of transcription, speech-to-text, dictation, or captions. The "What's new" page text was cut off. Conclusion: no transcription feature found in Logic Pro 12.x; not exhaustive, since only the summaries were read.

**F36. MacWhisper.** Sources: `https://docs.macwhisper.com/article/29-switching-to-a-whisperkit-model`, `.../article/57-macwhisper-command-line-tool`, `.../article/34-transcription-is-slower-than-expected`.
- Engines: local engines are "WhisperKit, ParakeetKit, Apple speech"; the model list also has `whisper-cpp:ggml-tiny.en` (80 MB), `whisperkit:openai_whisper-small` (483 MB), `parakeet-pro:nvidia_parakeet-v3_494MB`, and `apple:<locale>` ("Apple's on-device speech models provided by macOS 26+"). Cloud engines: OpenAI, Groq, Deepgram, ElevenLabs.
- Intel: "WhisperKit models are only available on M-Series Macs and are not supported on Intel-based machines." And: "Intel-based Macs lack dedicated machine learning hardware, which makes on-device transcription significantly slower." MacWhisper's advice for Intel users: use a Cloud Transcription provider.
- Model UI: a "Manage Models" screen; filter the list by "WhisperKit", then download. "The Turbo model is a great choice for many Macs!" The first load of a large model "may take up to a few minutes", later loads "are very fast".
- Where models live on disk: not stated in the docs read. Model verification: not stated.
- Progress, language pick, and button placement: not read in these articles.

### Q11. Apple Speech as the alternative

**F37. SFSpeechRecognizer on macOS.** Sources: Apple docs JSON at `https://developer.apple.com/tutorials/data/documentation/speech/...` (saved in `research/apple/`), WWDC19 session 256 `https://developer.apple.com/videos/play/wwdc2019/256/`.
- Availability: macOS 10.15 and later (`SFSpeechRecognizer`, `SFTranscriptionSegment`, `requiresOnDeviceRecognition`, `supportsOnDeviceRecognition` all list macOS 10.15).
- On-device: `SFSpeechRecognizer.supportsOnDeviceRecognition` is "a Boolean value that indicates whether the speech recognizer can operate without network access". `SFSpeechRecognitionRequest.requiresOnDeviceRecognition`: "Set this property to true to prevent an SFSpeechRecognitionRequest from sending audio over the network. However, on-device requests won't be as accurate." The request honors it only if `supportsOnDeviceRecognition` is true.
- Limits: the class doc says "Plan for a one-minute limit on audio duration" for the network-based service, plus per-device and per-app daily request limits. WWDC19: "A server-based recognition support has limits on number of requests and audio duration. With on-device recognition, these limits do not apply." Also: "The number of languages supported on server are more than on-device", "over 10 languages supported for on-device recognition" (2019), "all Mac devices are supported". The number of on-device languages in 2026 and the Spanish status are not in the docs read. Open question P12.
- Permission: the key `NSSpeechRecognitionUsageDescription` must be in `Info.plist`: "If this key is not present, your app will crash when it calls [requestAuthorization]". It applies "regardless of whether you set [requiresOnDeviceRecognition] to true or false". The system shows the key text in the prompt. The WWDC19 session says the user also needs Siri enabled for the server path (stated for macOS support).
- Word level: `SFTranscriptionSegment` has the text, alternative strings, `confidence`, `timestamp`, and `duration`. The doc says a segment "represents an utterance, which is a vocalized word or group of words that represent a single meaning to the speech recognizer". In practice it is a word. Not verified here.
- Files: `SFSpeechURLRecognitionRequest` for an audio file.
- Intel: "all Mac devices are supported" (WWDC19, 2019).

**F38. SpeechAnalyzer and SpeechTranscriber.** Sources: `https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json` and neighbors; WWDC25 session 277 `https://developer.apple.com/videos/play/wwdc2025/277/`.
- Availability: macOS 26.0 and later (also iOS, iPadOS, tvOS, visionOS 26). The class `SpeechTranscriber.isAvailable` is "whether this module is available given the device's hardware and capabilities". WWDC25: available "for all platforms but watchOS with certain hardware requirements".
- Models: "machine-learning models downloaded from Apple's servers and managed by the system" through `AssetInventory`. The system "retains and updates it automatically, and shares it with other apps". The app gets "a certain number of locale-specific asset reservations". The model "does not increase the download or storage size of your application, nor does it increase the run-time memory size" (WWDC25).
- Word times: set `attributeOptions: [.audioTimeRange]` (`SpeechTranscriber.ResultAttributeOption.audioTimeRange`: "Includes time-code attributes in a transcription's attributed string"). Each run of the attributed string has an `audioTimeRange` (`CMTimeRange`) in WWDC25.
- Privacy: the "Asking permission" article says the Info.plist prompt applies to `SFSpeechRecognizer` server use, and "SpeechTranscriber modules don't send audio data of the user's voice to Apple's servers" (text as read; the exact subject of the sentence is garbled in the JSON).
- Fallback: `DictationTranscriber` "supports the same languages, speech-to-text model, and devices as iOS 10's on-device SFSpeechRecognizer" and needs no Siri or dictation setup by the user (WWDC25).
- Languages: the list is a run-time call (`SpeechTranscriber.supportedLocales`, `installedLocales`). No list in the docs read. Spanish status unknown here.
- Intel and the dev Mac: macOS Tahoe 26 supports only these Intel Macs: MacBook Pro (16-inch, 2019), MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports), iMac (Retina 5K, 27-inch, 2020), Mac Pro (2019) (`https://support.apple.com/en-us/122867`). The dev Mac (i5-8259U, macOS 15.7) is not on the list. So SpeechAnalyzer cannot run on it. Whether `isAvailable` is true on those four Intel models is not in the sources.
- The app supports macOS 14. SFSpeechRecognizer covers macOS 14 and 15. SpeechAnalyzer covers macOS 26 only.

### Q12. Distribution

**F39. Bundle versus download.**
- Bundle sizes (F18): base 141.1 MiB, small-q5_1 181.3 MiB, small 465 MiB, turbo-q5_0 547 MiB. Inference: ggml F16 and quantized weights are high-entropy data, so DMG compression gains little (not measured). For scale, `Sources/CLame` is 916 KB (decision 0034). A model in the app bundle also changes the code signature work: the ad-hoc signature covers all files in `Contents/Resources`.
- Download on first use: needs a network call, a progress UI, a hash check (below), a resume or retry, and a place to store the file.
- Apple guidance for the storage place: `~/Library/Application Support/<bundle id>/` "Contains all app-specific data and support files... that your app creates and manages on behalf of the user"; `~/Library/Caches/<bundle id>/` "Contains cached data that can be regenerated as needed. Apps should never rely on the existence of cache files". Source: `https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html`. A model that the app downloads once and the user chose is closer to Application Support. Set `URLResourceValues.isExcludedFromBackup = true` for it: "Use this property to exclude cache and other app support files that aren't necessary in a backup. Set this property each time you save a file because some common file operations cause this property to reset" (`https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey`). Inference: the choice between the two folders is a design decision; no source decides it.
- Checksum: pin the SHA-256 from F18 in the app, and check size and hash after the download. Use the pinned Hugging Face revision URL (F18) so the file cannot change under the hash.
- The official script `models/download-ggml-model.sh` does not verify any checksum. It uses `curl -L --fail --retry 5 ...` (or `wget`, `wget2`) and checks the exit status only. It also skips a download when the file already exists. Source: the script text in the source tree.
- MacWhisper: its docs do not say how it verifies a download or where it stores models (searched `docs.macwhisper.com`). Not confirmed.
- Core ML models and VAD models are separate downloads (F17, F28): the silero VAD file is 0.85 MiB and could ship in the bundle.
- Files from the web need the `com.apple.quarantine` question: a file the app downloads with `URLSession` is not quarantined by default. Inference, not checked.

## Open questions (probe at Phase 4)

State on 2026-11-24: F112 is done, and the probes P1 to P15 are answered or ran in the run of decision 0065 (`docs/decisions/0065-whisper-transcription.md`).

- P1. Does ggml Metal run correctly on the dev Mac Intel iGPU? Probe: transcribe `samples/jfk.wav` with `base` twice, once with `use_gpu = true` and once with `false`, on the i5-8259U; compare the text and the encoder time; read the `ggml_metal_device_init` log lines (GPU family, simdgroup, unified memory).
- P2. Speed of the real vendored build on the dev Mac. Probe: a 10-minute Spanish file, `base` and `small`, 4 threads, 1 file x 3 runs, SwiftPM release build with the planned flags; record encoder and decoder time per window with `whisper_print_timings`, and `whisper_print_system_info()` (it shows `SSE3`, `AVX`, `AVX2`, `FMA`, `F16C`, `BLAS`). Compare with F20 and F21. Also measure the Accelerate gain (BLAS on and off). Plan gate 1 (W2): `swift test` builds C and C++ at -O0, so S0 also times the slow tests in a debug test build (plan S0 step 9).
- P3. Do the arch files collide in a SwiftPM universal build? Probe: build the vendored target with `--arch arm64 --arch x86_64`, look for duplicate symbols from `arch/x86/quants.c` and `arch/arm/quants.c`; then test the wrapper-file fix.
- P4. Can `#pragma clang attribute` + `target("avx2,fma,f16c")` + hand-defined `__AVX2__`/`__FMA__`/`__F16C__` build and run the AVX2 path with no `unsafeFlags`? Probe: one wrapper for `ggml-cpu.c`, `vec.cpp`, `ops.cpp`, `arch/x86/quants.c`; check that `ggml_cpu_has_avx2()` returns 1 and that a `__builtin_cpu_supports("avx2")` guard falls back on a non-AVX2 CPU (use a `sysctl` check for the dev Mac).
- P5. Does SwiftPM or the Swift driver build an `x86_64h` slice? Probe: `swift build --triple x86_64h-apple-macosx14.0` on a one-file C target; `lipo -archs` of the result.
- P6. What does the official XCFramework macOS x86_64 slice contain? Probe: unpack `whisper-b5454-xcframework.zip` as data only; `nm` the x86_64 slice for `_generic` symbols, and read `whisper_print_system_info()` from a tiny test run. Needed only if the binary-target option stays alive.
- P7. Which ARM feature macros does the default arm64 compile define (`__ARM_FEATURE_DOTPROD`, `__ARM_FEATURE_FP16_VECTOR_ARITHMETIC`, `__ARM_FEATURE_MATMUL_INT8`)? Probe: print them from the vendored target at run time, or `whisper_print_system_info()` on an Apple silicon Mac.
- P8. Does the Xcode build system (two `--arch` values) compile `.metal` files of a SwiftPM C target into a `default.metallib` that `SWIFTPM_MODULE_BUNDLE` finds? And does `bundle.sh` copy the resource bundle into the `.app`? Probe: a Metal-enabled copy of the target, one arm64 Mac, check the log line `ggml_metal_library_init: loading '.../default.metallib'`. Also test the glued-source option (F10).
- P9. Memory use per model. Probe: RSS and peak footprint during a 10-minute run for `base`, `small`, `small-q5_1`, `large-v3-turbo-q5_0` on the dev Mac and an Apple silicon Mac.
- P10. Does `new_segment_callback` fire for every window when DTW is on? Probe: a 2-minute file, `dtw_token_timestamps = true` and `flash_attn = false`, count callbacks against `whisper_full_n_segments`. Also check the DTW token times against a known word timing and measure the speed cost of `flash_attn = false`.
- P11. WER of `base`, `small`, `small-q5_1`, `large-v3-turbo-q5_0` on a Spanish test set (Common Voice or Fleurs es), run on the vendored build, compared with F30.
- P12. On macOS 15.7 (and 14 if available): `SFSpeechRecognizer.supportedLocales()` and, for `es-ES`, `supportsOnDeviceRecognition` and the quality on a 10-minute file with `requiresOnDeviceRecognition = true`. Also check the audio length limit of on-device recognition for a 1 h file.
- P13. Warning debt. Probe: build the vendored target under `swift build` and under the Xcode path (`--arch arm64 --arch x86_64`) with `treatAllWarnings(as: .error)`; count the warnings per file. The upstream Apple build passes `-Wno-macro-redefined -Wno-shorten-64-to-32` (F8) and decision 0034 (U2) found 26 LAME warnings per arch. This file has 4.5 MB of source against 916 KB for LAME, and the repo check refuses `disableWarning`, `treatWarning`, and `unsafeFlags`.
- P14. Dev Mac CPU features. Probe (read only, no build): `sysctl -n machdep.cpu.features machdep.cpu.leaf7_features` on the dev Mac. The probe was tried twice with `scripts/with-lock.sh scripts/probe.sh` and stopped in the lock wait both times (a `make test-filter` run held the lock), so it did not run. Expected: AVX2, FMA, F16C (not verified).
- P15. Cancel and progress UX. Probe: the time from `abort_callback` returning true to `whisper_full` return, on `small` with 4 threads, and the progress callback interval on `small`. Plan gate 1 (W6): `whisper_vad_detect_speech_no_reset` (whisper.cpp:5264) takes no abort callback, so S0 also sets the flag at 0 % of a 10 min piece (plan S0 step 7).

## Claims that no source confirmed

- The SSE-only baseline speed on x86 (F14). No clang macOS number exists.
- The speed of large-v3-turbo on Intel (F21): proxy from the `large` row only.
- Decoder time on Intel (not in F21).
- That `target("avx2")` does not define `__AVX2__` (F13, Inference).
- Whether SwiftPM builds `x86_64h` (F13).
- That SwiftPM compiles every source for both slices and so duplicates the arch symbols (F5).
- That the official XCFramework x86_64 slice is generic (F8).
- Metal behavior on Intel iGPU, and Core ML behavior on Intel (F16, F17).
- Descript cloud processing, Hindenburg engine name, FCP on-device and progress, MacWhisper model folder and checksum method, Logic Pro (F32 to F36).
- The on-device language list of `SFSpeechRecognizer` and `SpeechTranscriber`, and Spanish on-device status (F37, F38).
- Spanish WER of large-v3-turbo and of the quantized files (F30, F31).
- DMG compression of model files, and quarantine of downloaded files (F39).

## Summary for the plan

- Source target is possible only as CPU-only at the clang Darwin baseline on x86_64 (penryn: SSE4.1, no AVX2, FMA, or F16C), because Package.swift cannot hold `-mavx2` (F12, F13). It is possible with Accelerate and Metal on arm64.
- The cost of a source target: 62 to 73 files, 4.2 to 4.6 MB, hand-made `ggml-version.h` and `WHISPER_VERSION`, wrapper files for the arch collision, and the warning debt under `treatAllWarnings(as: .error)` (F3, F5, P13).
- A binary target is not a good fit: v1.9.3 to v1.9.5 have no XCFramework, the newest is the nightly `b5454` (65.8 MB), and 0034 rejected prebuilt binaries (F8).
- Apple Speech: SFSpeechRecognizer works on macOS 14 and 15 including Intel, with on-device mode and word segments, but its on-device language list is not confirmed (F37). SpeechAnalyzer is macOS 26 only and the dev Mac is not on the Tahoe list (F38).
- Metal on Intel: no CPU fallback and reports of garbage on AMD GPUs, so set `use_gpu = false` on x86_64 (F16, Inference).
- Default model: `base` multilingual, 141.1 MiB (147,951,465 bytes, SHA-256 `60ed5bc3...fba2efe`). `small` (465 MiB; `small-q5_1` 181 MiB) is the opt-in upgrade. Turbo-q5_0 (547 MiB) is for Apple silicon only.
- CPU speed risk on this Intel Mac: base is about 0.04 to 0.18 x real time for the encoder alone, small about 0.14 to 0.76, turbo at least 1.2 (F21). Decoder time is extra. Spanish WER of base is 9.9 (Fleurs) and 19.6 (Common Voice), which is weak for an edit transcript (F30).
- Word times: use DTW with `flash_attn = false`, or token times with `max_len = 1` and `split_on_word`; there is no word API, and the caller joins tokens on a leading space (F22 to F25).
- Long files: add VAD (Silero v6.2.0, 0.85 MiB), `entropy_thold` about 2.8, and a cancel through `abort_callback` (F26 to F29).

## Sources

whisper.cpp and ggml:
- `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5` and `.../tag/b5454`, `.../tag/v1.7.6`, `.../tag/v1.8.0`.
- `https://github.com/ggml-org/whisper.cpp/tree/v1.9.5`: `README.md`, `LICENSE`, `CMakeLists.txt`, `build-xcframework.sh`, `include/whisper.h`, `src/whisper.cpp`, `src/CMakeLists.txt`, `ggml/CMakeLists.txt`, `ggml/cmake/common.cmake`, `ggml/src/CMakeLists.txt`, `ggml/src/ggml-cpu/CMakeLists.txt`, `ggml/src/ggml-cpu/ggml-cpu.c`, `ggml/src/ggml-cpu/simd-mappings.h`, `ggml/src/ggml-cpu/arch/`, `ggml/src/ggml-blas/`, `ggml/src/ggml-metal/`, `examples/cli/cli.cpp`, `models/README.md`, `models/download-ggml-model.sh`, `models/download-vad-model.sh`, `models/generate-coreml-model.sh`, `examples/whisper.swiftui/README.md`, `examples/whisper.objc/README.md`.
- `https://github.com/ggml-org/whisper.cpp/pull/2873`, `.../issues/2869`, `.../issues/89` (and its comments), `.../issues/1507`, `.../issues/1724`, `.../issues/1851`, `.../issues/2812`, `.../issues/375`, `.../pull/1485`, `.../pull/3612`, `.../pull/3704`.
- `https://github.com/ggml-org/llama.cpp/issues/30702`, `.../issues/19563`, `.../issues/25866`, `.../issues/26949`.
- `https://raw.githubusercontent.com/ggml-org/whisper.spm/master/Package.swift`, `https://raw.githubusercontent.com/exPHAT/SwiftWhisper/master/Package.swift`.
- Hugging Face: `https://huggingface.co/ggerganov/whisper.cpp` (API tree JSON saved as `research/hf-tree.json`, README as `research/hf-model-readme.md`), `https://huggingface.co/ggml-org/whisper-vad`, `https://huggingface.co/openai/whisper-large-v3`, `https://huggingface.co/openai/whisper-large-v3-turbo`.
- `https://github.com/openai/whisper/discussions/2363`; paper `https://arxiv.org/abs/2212.04356` (ar5iv copy saved in `research/papers/`).

SwiftPM and compilers:
- `https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/TargetSourcesBuilder.swift` and `.../Sources/PackageModel/SupportedLanguageExtension.swift` (saved in `research/spm/`).
- `https://clang.llvm.org/docs/AttributeReference.html`, `https://clang.llvm.org/docs/LanguageExtensions.html` (saved in `research/clang/`).
- `https://github.com/llvm/llvm-project/blob/main/clang/lib/Driver/ToolChains/Arch/X86.cpp` and `.../AArch64.cpp` (saved in `research/llvm/`).

Apple:
- `https://developer.apple.com/tutorials/data/documentation/speech/sfspeechrecognizer.json` and the neighbor pages in `research/apple/` (SFSpeechRecognitionRequest requiresOnDeviceRecognition, supportsOnDeviceRecognition, SFTranscriptionSegment, SpeechAnalyzer, SpeechTranscriber, AssetInventory, audioTimeRange, "Asking Permission to Use Speech Recognition").
- `https://developer.apple.com/videos/play/wwdc2019/256/`, `https://developer.apple.com/videos/play/wwdc2025/277/`.
- `https://support.apple.com/en-us/105113` (macOS Sonoma 14 compatible Macs), `https://support.apple.com/en-us/122867` (macOS Tahoe 26 compatible Macs).
- `https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html`, `https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey`.
- `https://support.apple.com/guide/final-cut-pro/vere399dab5e/mac`, `https://support.apple.com/en-us/109503` (Logic Pro release notes), `https://support.apple.com/guide/logicpro/whats-new-in-logic-pro-lgcp4a62a494/mac`.

Vendor help:
- `https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2700/`, `https://hindenburg.com/products/radio-podcast/features/transcription/`.
- `https://help.descript.com/hc/en-us/articles/10249408168845`.
- `https://docs.macwhisper.com/` articles 29, 34, 57, and the collection `https://docs.macwhisper.com/category/10-transcription`.

Repo context (read only): `Package.swift`, `docs/decisions/0034-vendored-c-and-mp3-encoder.md`, `Sources/CLame/README.dirigible`, `scripts/bundle.sh`, `scripts/probe.sh`.
