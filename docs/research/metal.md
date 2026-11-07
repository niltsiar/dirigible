# Research: whisper.cpp v1.9.5 with the ggml Metal backend in the Dirigible SwiftPM target (backlog item 1517)

Date: 2026-11-03

Scope: seven questions from the lead orchestrator. The facts in `docs/research/whisper.md` (cited as "whisper.md F8 to F10, F16, F20, F21") and decision 0065 are not repeated.

Method: source files of the tag `v1.9.5` of `ggml-org/whisper.cpp`, read as raw files (GitHub tree API and `raw.githubusercontent.com`). Line numbers are those of that tag. The SwiftPM source is the branch `release/6.2` of `swiftlang/swift-package-manager`. No build, no probe, and no run happened. A claim with no owner source is marked "Inference:". Section "Open questions" lists the probes that were not run.

## Summary

| Q | Answer |
|---|---|
| 1 | SwiftPM adds `-fobjc-arc` to every Objective-C file on Darwin. The two ggml Metal `.m` files use manual `retain` and `release`, so they do not compile under the current Package.swift rules. The fix is an ARC port of the two files (a rewrite of about 54 sends and 17 struct fields, not a one-line edit each) or an `unsafeFlags` exception. The shader ships as 35 glued source texts compiled at run time (embed mode). It is not a `.metallib`. |
| 2 | ggml does not gate Metal to Apple silicon. The registry starts Metal, and compiles the shaders, in every process that touches ggml, even with `use_gpu = false` (F8). Inference (F8): on Intel Macs the Metal backend must not register, which is a source patch. |
| 3 | The bfloat kernels need MSL 3.1, which macOS 14 has. The matrix kernels need the Apple7 family (M1 and later). The residency-set code has `@available(macOS 15.0)` guards. The tensor API is optional and off below M5. |
| 4 | The abort callback does not stop a Metal graph. A stop lands between graphs. |
| 5 | A Metal transcript can differ from the CPU transcript. No source measures the size of the difference. |
| 6 | No same-chip, same-version pair exists. Inference (F16): Metal is about 8 to 11 times faster on the encoder on an M1 Ultra. |
| 7 | Verify on a tester Mac with Apple silicon. A GitHub arm64 runner has a paravirtual GPU that fails the kernel gates. |

## Q1. Smallest correct way to add the Metal backend

**F1. SwiftPM compiles each Objective-C file with ARC, and ggml-metal is not ARC code.** This decides whether the item can be planned.
- `ClangModuleBuildDescription.swift` line 266 adds `-fobjc-arc` for each clang file when the triple is Darwin ("Only enable ARC on macOS"). The XCBuild path sets `CLANG_ENABLE_OBJC_ARC = YES` (`PIFBuilder.swift` line 309). Both build paths of `bundle.sh` and `make build` get ARC.
- `ggml-metal-device.m` has 34 sends of `retain`, `release`, or `autorelease`, and `ggml-metal-context.m` has 20 (count by `rg`). Example: `[devices release];` at `ggml-metal-context.m:97`. The structs of the backend are `calloc` memory that holds `id<MTL...>` fields.
- The clang ARC specification says that a program is ill-formed if it contains a message send of `autorelease`, `release`, `retain`, or `retainCount` (section "Memory management methods"). It also says that `-fno-objc-arc` disables ARC and that the last of the two flags on the command line wins (section "General"). Source: `https://clang.llvm.org/docs/AutomaticReferenceCounting.html`.
- The ggml CMake files pass no ARC flag (`rg` finds none in `ggml/CMakeLists.txt` or `ggml/src/CMakeLists.txt`), so upstream builds both files with manual reference counting.
- `Package.swift` has no safe setting for ARC. Decision 0034 rejects `unsafeFlags`, and `scripts/check-warnings.sh` refuses it. Inference: `unsafeFlags(["-fno-objc-arc"])` works in a native build, because the generated flags come first and the clang text says the last of the two flags wins. For the XCBuild path, `CLANG_ENABLE_OBJC_ARC = YES` is a build setting, and nobody checked that the flag lands after it.
- Size of an ARC port. The two files hold at least 17 object-typed fields in C structs (`id<MTLDevice>`, `id<MTLCommandQueue>`, `id<MTLLibrary> objs[35]`, `NSLock *`, `NSMutableArray *`, `dispatch_group_t`, and more; `rg` count of fields in `struct ggml_metal_device`, `struct ggml_metal_library`, `struct ggml_metal`, and the pipeline and buffer structs). The code allocates them with `calloc` and ends them with `free` (55 `calloc` and `free` sites). The ARC specification has a section "Ownership-qualified fields of structs and unions", whose body this research did not read. Inference: a port must mark each field, or bridge it, and must set each field to nil before `free`, so it is a rewrite of the ownership code, not 54 deletions.
- Inference: the options are (a) the ARC port, listed in `README.dirigible`; (b) an exception to decision 0034 for `unsafeFlags(["-fno-objc-arc"])` on a separate target that holds only the two `.m` files, with a change of `check-warnings.sh`. Neither was built. Open question P1.
- whisper.md F7 notes that `ggml-org/whisper.spm` left Metal as a TODO ("I can't figure out how to build ggml-metal.m"). ARC is a likely cause. Not confirmed by the author.

**F2. Files to add.** Source: `ggml/src/ggml-metal/CMakeLists.txt` lines 14-23, tree API of `v1.9.5`.
- Eight source files, 594,354 bytes: `ggml-metal.cpp`, `ggml-metal-device.cpp`, `ggml-metal-common.cpp`, `ggml-metal-fusion.cpp`, `ggml-metal-ops.cpp`, `ggml-metal-tuning.cpp`, `ggml-metal-device.m`, `ggml-metal-context.m`.
- Seven private headers in the same folder (`ggml-metal-common.h`, `-context.h`, `-device.h`, `-fusion.h`, `-impl.h`, `-ops.h`, `-tuning.h`) and one public header, `ggml/include/ggml-metal.h`.
- `kernels/` has 40 files, 680,225 bytes: 37 `.metal` and 3 `.h` (`common.h`, `dequantize.h`, `quantize.h`). `GGML_METAL_LIBS` in `ggml-metal-impl.h` lists 35 kernel sources. The other two `.metal` files (`fa_common.metal`, `fa_vec_common.metal`) are includes. whisper.md F10 says "36 files" and "about 1.4 MB": the counts here replace those two numbers.
- The `.m` files import only Foundation and Metal (no `MetalKit` in `rg`). The target needs `linkedFramework("Metal")` and `linkedFramework("Foundation")`. The CMake file also links MetalKit. Inference: the link does not need it.
- Inference: the 593 KB of new C++ and Objective-C code needs the same warning work as the CPU files (`treatAllWarnings(as: .error)`, `-Wshorten-64-to-32` in XCBuild). The count of sites is unknown.

**F3. Defines.** Source: `ggml/src/ggml-backend-reg.cpp` lines 37-39 and 123-125; `ggml-metal-device.m` lines 34, 463-500; whisper.md F4.
- `GGML_USE_METAL`: registers the backend (`ggml_backend_metal_reg()`) and enables the KV padding of 32 in `whisper.cpp:1156`.
- `GGML_METAL_EMBED_LIBRARY` (define it as 1): `ggml-metal-device.m` tests it with `#if`, not `#ifdef`.
- Without `GGML_METAL_EMBED_LIBRARY`, the code uses `SWIFTPM_MODULE_BUNDLE` under `#ifdef SWIFT_PACKAGE` (line 501). SwiftPM defines `SWIFT_PACKAGE=1` for each target (`ClangModuleBuildDescription.swift` line 456). It generates the `SWIFTPM_MODULE_BUNDLE` header only when the target has resources and an Objective-C file (line 489). A target with no resources fails to compile that branch.

**F4. How to ship the shader.** There are three routes. Embed mode is the only one that works with no extra build step.
- Embed mode (`GGML_METAL_EMBED_LIBRARY`). The device code declares `extern const char ggml_metallib_<kind>_start[]` and `_end[]` for each of the 35 kinds (lines 470-482). At init it compiles each text with `newLibraryWithSource` in parallel (`ggml_metal_library_compile_all`, line 486). So embed mode embeds source text and compiles it at run time. It does not embed a `.metallib`.
- The CMake step makes each text. It runs `cat` on the headers and the kernel, removes `#include "common.h"`, `"dequantize.h"`, `"quantize.h"`, `"fa_common.metal"`, `"fa_vec_common.metal"`, and `#pragma once`, then replaces the sentinel line `__embed_ggml-common.h__` with `ggml-common.h`, and `#include "ggml-metal-impl.h"` with that file (`CMakeLists.txt` lines 77-143). The sentinel is a bare word, not an `#include` (`kernels/dequantize.h` line 8). So the raw `.metal` files compile on no path (SwiftPM resource, XCBuild, or run-time flatten) until the glue step runs.
- Inference: a vendoring script can do the glue step once and commit 35 texts. SwiftPM has no `.incbin` step. Two ways to give the symbols: an assembly `.s` file per kind with `.incbin` (SwiftPM compiles `.s` files, `SupportedLanguageExtension.swift`; whether the integrated assembler finds the text through a `headerSearchPath` is not checked), or a C file with an array initializer per kind (`const unsigned char`, not a string literal, because the repo removed `-Woverlength-strings` pragmas). The end symbol of an array needs a patch of `ggml-metal-device.m` (a size instead of `_end`). Source of the idea: none in upstream.
- Precompiled `default.metallib` route. The CMake non-embed branch runs `xcrun metal -c` for each kernel and `xcrun metallib` (lines 145-260). The macOS version flag is `GGML_METAL_MACOSX_VERSION_MIN` (line 193) and the language flag is `GGML_METAL_STD` (line 201). Without them the target OS may follow the host. Inference: a metallib built on macOS 15 may not load on macOS 14, so the command needs `-mmacosx-version-min=14.0`.
- Xcode 26 ships without the Metal compiler. Apple says to download "the optional Metal Toolchain" (`xcodebuild -downloadComponent metalToolchain`, `https://developer.apple.com/tutorials/data/documentation/xcode/downloading-and-installing-additional-xcode-components.md`). A third-party PR gives the size as 704 MB (`aethersdr/AetherSDR` pull 4553).
- The metallib route also needs the loader: a `.metallib` as a SwiftPM resource, or a file next to the executable (`ggml_metal_find_metallib`, lines 407-430, which reads `argv[0]` directory). The generated accessor of SwiftPM for Objective-C reads `[[NSBundle mainBundle] bundleURL]` plus the bundle name (`ClangModuleBuildDescription.swift` lines 496-508). In a `.app`, `bundleURL` is the folder of the app, not `Contents/Resources`. Inference: the bundle is not found there and the code falls back to the absolute build path. Not tested. The XCBuild path uses another accessor (`GENERATE_RESOURCE_ACCESSORS`, `PIFBuilder.swift` lines 505 and 741).
- Run-time source route (no `default.metallib`): the code reads `kernels/<name>.metal` as resources or from the folder in the environment variable `GGML_METAL_PATH_RESOURCES` (lines 553-600). Decision 0065 rejects code paths that read a path from the environment, and this one reads shader source. It needs the glue step too, because of the sentinel.
- SwiftPM and `.metal`. `.metal` is a resource rule only in the list of Xcode file types (`TargetSourcesBuilder.swift` lines 729-736 and 775-782). For tools version above 5.4, a build system gets that rule only if it passes `additionalFileRules` (line 141). Inference: native `swift build` does not match `.metal`, and an unmatched file gives an "unhandled file" warning, which the zero-warning rule turns into a failure, unless `Package.swift` excludes the folder. Not tested. SwiftPM 6.2 does not compile `.metal` into a `.metallib` for a C target in the native build (whisper.md F9 holds).
- Third-party precedent for a precompiled and embedded binary: `aethersdr/AetherSDR` pull 4553 (merged 2026-07-31) patches `ggml-metal/CMakeLists.txt` and `ggml-metal-device.m` of a vendored whisper.cpp to embed a `xcrun metal | metallib` binary and load it with `newLibraryWithData:`. The author lists it as a local patch, not an upstream feature.

**F5. Run-time cost of embed mode.** The shader compile runs at the first touch of ggml, in each process, and the system caches the result.
- Source: `ggml-metal-device.m:1310` (library init inside device init). `cjpais/Handy` issue 2340 (2026-10-27) logs "loaded 20 libraries from embedded data in 41.248 sec" at first launch and 0.080 sec at second launch, on a Radeon Pro 580X (Intel iMac). No Apple-silicon number was found. Open question P2.

**F6. Other facts for the plan.**
- `ggml_metal_library_init` in embed mode reads no file and no environment variable for the shader (`#if GGML_METAL_EMBED_LIBRARY`, lines 463-500). The branch with `GGML_METAL_PATH_RESOURCES` is in the `#else` part and is not compiled.
- Metal still reads many `GGML_METAL_*` environment variables for tuning (`getenv` in `ggml-metal-device.m` and `ggml-metal-context.m`), and `ggml_backend_metal_reg()` calls `setenv("AGX_RELAX_CDM_CTXSTORE_TIMEOUT", "1", true)` (`ggml-metal.cpp` at line 1035). None of them loads code. The 0065 consequence about environment variables needs a line for them.
- VAD runs on the CPU: `whisper_vad_init_context` forces `use_gpu = false` (`whisper.cpp:4818-4819`).

## Q2. Intel Macs and the fallback

**F7. ggml does not gate Metal by CPU architecture.** Source: `ggml/CMakeLists.txt` lines 95-101; `ggml-metal-device.m` lines 1134-1146.
- CMake sets `GGML_METAL_DEFAULT ON` for every Apple target, with no arch test.
- Family flags: `has_simdgroup_reduction` = Apple7 or Metal 3; `has_simdgroup_mm` = Apple7; `has_bfloat` = Metal 3 or Apple6. Apple documents Metal 3 for: Apple M1 and later, AMD Vega, AMD 5000 and 6000 series, Intel Iris Pro Graphics, and Intel UHD Graphics 630 (`https://developer.apple.com/tutorials/data/documentation/metal/mtlgpufamily/metal3.json`). So an Intel iGPU or an AMD GPU of those lines gets `has_simdgroup_reduction = true`, and `ggml_metal_supports_mul_mat_op` accepts the matrix products on the `mul_mv` kernels (`ggml-metal-device.m:1512-1535`). Apple does not list "Iris Plus Graphics" for Metal 3. Whether the dev Mac passes the Metal 3 test is not known.
- Flash attention needs `has_simdgroup_mm` (line 1770: `return has_simdgroup_mm;`), so it stays on the CPU on Intel and AMD GPUs.
- There is no check that turns Metal off on x86_64. The code has `#if TARGET_CPU_X86_64` only to print the Common family and to prefer shared buffers for an eGPU (lines 1271 and 1336).
- whisper.md F16 lists reports of wrong output on Intel Macs with AMD GPUs (llama.cpp issues 30702, 19563, 25866, 26949).

**F8. The registry starts Metal in each process, whatever `use_gpu` says.** This changes the answer for the Intel slice.
- `ggml_backend_registry` calls `register_backend(ggml_backend_metal_reg())` in its constructor under `GGML_USE_METAL` (`ggml-backend-reg.cpp:123-125`). `ggml_backend_metal_reg()` calls `ggml_backend_metal_device_init`, which calls `ggml_metal_device_get` (`ggml-metal.cpp:1000-1004`, `ggml-metal-device.cpp:22-28`). That calls `ggml_metal_device_init`, which calls `ggml_metal_library_init` (`ggml-metal-device.m:1310`) and compiles the shaders.
- The registry is a singleton built at the first call of `ggml_backend_dev_count()`. `use_gpu = false` only changes which device `whisper_backend_init_gpu` picks (`whisper.cpp:1308`). So it does not stop the compile.
- Field reports match: `cjpais/Handy` issue 2340 (Intel Core i5-9600K, Radeon Pro 580X, macOS 15.8.1): the compile of the embedded source never finished, also with the accelerator set to CPU, and `MTLCompilerService` used one core for more than 6 minutes. The maintainer: "we definitely should build this with GGML Metal OFF for x86 Macs". `aethersdr/AetherSDR` pull 4553 (Radeon Pro 560X): the run-time compile ran 75 minutes with no end; the fix keeps Intel Macs CPU-only and reports `simdgroup reduction = false`, `simdgroup matrix mul. = false`, `has bfloat = false` on that GPU.
- Inference: the x86_64 slice must not register the Metal backend. SwiftPM cannot set a define for one arch (decision 0065 D1b has the same limit), so the patch is `#if defined(GGML_USE_METAL) && defined(__arm64__)` in `ggml-backend-reg.cpp`, listed in `README.dirigible`. The `.m` and `.cpp` files can still compile in the x86_64 slice. The same patch is needed in the `whisper.cpp:1156` branch only if the KV padding matters (it does not when the GPU is unused).

**F9. What ggml does on a Mac whose GPU it cannot use.**
- No Metal device: `whisper_backend_init_gpu` logs "no GPU found" and returns null, and `whisper_backend_init` goes on with the CPU backend (`whisper.cpp:1302-1339` and 1341-1368). A device that fails to start gives "failed to initialize ... backend" and the same fall through.
- Device present but low family: the backend starts, and each op that `supports_op` refuses goes to the CPU through the scheduler. Source: ggerganov, llama.cpp issue 8617 (2024-07-22): "When an operation is not supported by the GPU, llama.cpp will automatically copy the necessary data to the CPU and compute it there". There is no fallback for a wrong result of a kernel that the device accepts.
- GitHub arm64 runners show this case: the device is "Apple Paravirtual device", family `MTLGPUFamilyCommon3`, `simdgroup reduction = false`, `simdgroup matrix mul. = false` (same issue 8617, log of that date). In 2024 a small model on that device gave looping output. ggerganov wrote on 2026-03-06 (llama.cpp pull 19802): "I think it is a problem in the Metal backend when it uses a Paravirtual Metal device". The workflow `build-apple.yml` of llama.cpp excludes tests for that reason.
- `whisper_context_default_params().use_gpu` is `true` and `flash_attn` is `true` (`whisper.cpp:3715-3716`).

## Q3. Features that macOS 14 needs

**F10. MSL version, matrix kernels, and bfloat.**
- Runtime compile uses the newest language version that the OS has (Apple, `MTLCompileOptions.languageVersion`: "By default, Metal uses the most recent language version"). MSL 3.1 starts at macOS 14, MSL 4.0 at macOS 26 (`MTLLanguageVersion.version3_1`, `.version4_0` documentation JSON). `kernels/common.h` lines 31-33 undefine `GGML_METAL_HAS_BF16` when `__METAL_VERSION__ < 310`. So on macOS 14 the bfloat kernels compile.
- The host sets `GGML_METAL_HAS_BF16` when `has_bfloat` is true (`ggml-metal-device.m:457-459`). `has_bfloat` is Metal 3 or Apple6. The kernels `mul_mm.metal` and `fa_common.metal` call `make_filled_simdgroup_matrix` and use `simdgroup_half8x8` without a feature macro. The host gates them with Apple7 (`has_simdgroup_mm`). Apple documents Apple7 as "the Apple A14 and M1 GPUs" (`MTLGPUFamily.apple7`). So each Apple-silicon Mac that runs macOS 14 has them.
- Inference: macOS 14 runs on M1 and later, so the 14 floor needs no higher family than Apple7 on Apple silicon.
- Residency sets (`MTLResidencySet`) are a macOS 15 API. The code compiles them in when the SDK is macOS 15 or later (`ggml-metal-device.m:20-24` tests `__MAC_OS_X_VERSION_MAX_ALLOWED >= 150000`, not the deployment target). Each use sits inside `@available(macOS 15.0, ...)` (lines 1002, 1023, 2041, 2073), and the type is not named in a declaration (line 2000: "not available on certain OSes"). So the macOS 14 floor holds with no patch. Inference: the build gives no `-Wunguarded-availability` warning for them. Not compiled.

**F11. The tensor API is optional.**
- `has_tensor` needs the Metal 4 family (line 1146). It is off unless the device name has "M5", "M6", "A19", or "A20", or the environment has `GGML_METAL_TENSOR_ENABLE` (lines 1151-1163, log "tensor API disabled for pre-M5 and pre-A19 devices"). The code then compiles two probe kernels, and turns the API off if they fail (lines 1165-1260).
- The shader macro `GGML_METAL_HAS_TENSOR` and the language version 4.0 are set only when `has_tensor` is true (lines 203-208, 460-462). In embed mode, no second library is needed. In the metallib route, a missing `ggml-tensor.metallib` turns the API off (line 543).
- Risk, third party: `ollama/ollama` issue 14432 (2026-02-26, open) reports an M5 on macOS 15 that fails with a `static_assert` in `MPPTensorOpsMatMul2dImpl.h` at library init, on an older ggml snapshot. v1.9.5 has the probe kernels, which that snapshot may not. Open question P6.

## Q4. Abort callback and Metal

**F12. The abort callback does not stop a Metal graph. A stop lands between graphs.**
- whisper.cpp gives the callback to a backend only through the registry function `ggml_backend_set_abort_callback` (`whisper.cpp:184`, and the Dirigible patch at lines 209-211 of the vendored file). The Metal registry function `ggml_backend_metal_get_proc_address` (`ggml-metal.cpp:945-990`) does not export that name. Only `ggml-cpu.cpp:670` does. So the helper gets null for Metal.
- Even a direct call of `ggml_backend_metal_set_abort_callback` would not help: `ggml_metal_graph_compute` reads the callback in one place, `ggml-metal-context.m:644`, inside `if (use_capture && ctx->capture_started)` (line 602). `capture_compute` starts at 0 and the function decrements it before the test (lines 165, 515-519), so `use_capture` is false unless the environment variable `GGML_METAL_CAPTURE_COMPUTE` is set (GPU capture for debugging). The other two uses (lines 586 and 768) only skip a `commit` when `n_cb` is above 2, and whisper uses `n_cb = 1` (`ggml-metal.cpp:633, 728`).
- Effect: the graph goes to the GPU and the CPU thread waits (`ggml_backend_synchronize`). The abort callback that Dirigible patched into `whisper_encode_internal`, `whisper_decode_internal`, and the VAD loop runs between graph calls. The stop latency is the rest of the current encoder or decoder graph on the GPU, plus the CPU-side checks that stay (mel frames, VAD windows, signal energy).
- Data: encoder time of one 30 s window, M2 Ultra, Metal, flash attention on: 201.88 ms for large-v3-turbo-q5_0 (F15). A base M1 is slower. Inference: below the 2 s bound on every Apple-silicon Mac. No source measures a stop on a base M1. Open question P3.
- Decoder note: one decoder step takes about 1.3 ms on M2 Ultra (turbo-q5_0, F15), so the decoder part adds no real latency.

## Q5. Accuracy

**F13. A Metal transcript can differ from the CPU transcript of the same model. No source gives the size.**
- The CPU path with Accelerate converts the quantized weights to F32 and calls BLAS (whisper.md F20, F21). The Metal matrix kernel `kernel_mul_mm` uses `half` tiles for both inputs, with a float accumulator (`mul_mm.metal:849-851`, `simdgroup_float8x8 mc` at 206). So the activations round to F16 before the product. Inference: small numeric differences in the logits that can change a token at a close decision.
- Related report, CUDA backend, the same ggml matmul rule: whisper.cpp issue 1692 (2023-12-27): with the CUDA backend, large-v2 hallucinated on a Chinese sample, and with `-ng` (CPU) it did not. slaren found "precision differences with the matrix multiplication" and that `GGML_PREC_F32` fixed most of the error. A report in issue 1768 (jettoblack, 2024-02-12) saw hallucinations "on a Mac using the Metal gpu backend" with a test branch. No Metal-specific WER comparison was found.
- Flash attention is the default in v1.9.5 (`whisper.cpp:3716`) for both backends. `dtw_token_timestamps` is not supported with it (`whisper.cpp:3817`).
- Inference: the Dirigible cases C13, C14, C15, and C24, and the word-end step of D7, need a rerun on Metal. The D7 pause alignment uses the audio, not the model, so it holds, but the token times that it starts from can move.

## Q6. Speed

**F14. Encoder time (ms) for one 30 s window, from issue 89 and the release notes. "Config" is the field of the table.**

| Chip | Config, OS, threads | Commit, date | base | small | large |
|---|---|---|---|---|---|
| M1 Pro | NEON BLAS (CPU), 13.2.1, 8 | 09e9068, 2023-03-20 | 187 | 702 | 3,796 |
| M1 Ultra | NEON BLAS (CPU), 13.2, 4 | 2bee265, 2023-02-02 | 266 | 806 | 3,895 |
| M2 Max | NEON BLAS (CPU), 13.3, 4 | 0a2d121, 2023-04-03 | 230 | 734 | 3,553 |
| M2 | NEON BLAS (CPU), 13.0.1, 4 | 1a91c19, 2023-01-24 | 329 | 1,014 | 5,466 |
| M1 Ultra | NEON BLAS METAL, 14.0, 20 | c76c11e, 2023-10-02 | 31.55 | 81.78 | 358.84 |

Sources: issue 89 comments 1476806570, 1414495683, 1493504252, 1401394565, 1742441700.

**F15. Metal rows of the v1.7.6 release (M2 Ultra, flash attention on, 1 thread, commit dc8dda60, 2025-04).**

| Model | Encoder ms | Decoder ms per token |
|---|---|---|
| base | 13.52 | 1.39 |
| small | 38.78 | 2.72 |
| small-q5_0 and small-q5_1 | 44.01 and 44.02 | 2.64 and 2.66 |
| large-v3-turbo | 170.22 | 1.46 |
| large-v3-turbo-q5_0 | 201.88 | 1.27 |

Source: `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.7.6`.
- M4 Mac mini (4 threads, 2025-04-24, issue 89 comment 2827317514): large-v3 569.74 ms, large-v3-turbo-q5_0 457.06 ms, small.en 95.17 ms. The log line of that run says `WHISPER : COREML = 1` and loads a Core ML model for small.en. So the small.en row is not a Metal row. The other two rows have no Core ML file, so they likely ran on Metal. Not confirmed.

**F16. What the numbers say, and what they do not.**
- No row pairs CPU and Metal on one chip with one commit. The pair on one chip (M1 Ultra) differs by 8 months of code and by threads.
- Inference (ratio of the M1 Ultra rows of F14): Metal is about 8.4 times faster on base (266 against 31.55), 9.9 times on small, and 10.9 times on large.
- There is no CPU row for large-v3-turbo on Apple silicon. Inference: the turbo encoder equals the large-v3 encoder (whisper.md F31), so the CPU encoder takes about 3.5 to 3.9 s on M1 Pro, M1 Ultra, and M2 Max, and Metal takes 0.2 to 0.46 s (M2 Ultra, M4). That is about 8 to 18 times.
- The numbers are old and the code changed (the v1.7.6 notes say "Metal FA improvements"). The first launch also pays the shader compile of F5. Open question P2.

## Q7. Verify a Metal build with an Intel dev Mac

**F17. What the Intel dev Mac can verify.**
- Build the arm64 slice with Metal files and the ARC fix: `swift build --arch arm64` and the two-arch `scripts/bundle.sh` run on the Intel Mac today for the CPU files (README.dirigible, last paragraph).
- Run the x86_64 slice and check that it never starts Metal: no `ggml_metal_` line in the journal and no `MTLCompilerService` process. This tests the patch of F8, and it avoids the hang that Handy issue 2340 shows. Do not start the Metal backend on the Intel GPU for a test.
- Inference: with the Metal Toolchain installed (a 704 MB download that the lead forbids now), `xcrun metal -c` on each glued text checks that the shaders compile to AIR for macOS 14. This is optional for embed mode, because embed mode compiles on the device.

**F18. Options for the GPU run.**

| Option | What it proves | Cost |
|---|---|---|
| Tester Mac with Apple silicon runs the universal app or the CLI | The real kernel path, the family log lines, the speed, the stop time, the transcript diff | A person, a DMG or a build copy, and a quarantine step for the ad-hoc signature. No price. |
| GitHub-hosted arm64 runner (`macos-15`, `macos-26`, `macos-latest`) | Compile, link, ARC fix, library init, CPU fallback. Not the kernel path. | Minutes of the account. Not checked. |
| GitHub larger runner, arm64 (M2, 5 cores) | Same as above. Inference: also virtualized. | Not checked. |
| AWS EC2 `mac2.metal` (M1, 8 GPU cores) or `mac2-m2.metal` | The real kernel path on a remote Mac | Dedicated host, minimum allocation 24 hours. Price not fetched. |

- GitHub runners: the docs of the runner reference list a Tesla T4 for Ubuntu and Windows as the only GPU spec, and no macOS GPU SKU (`github/docs`, `content/actions/reference/runners/larger-runners.md`). The macOS limits list says nested virtualization is not supported (`data/reusables/actions/macos-runner-limitations.md`). Issue `actions/runner-images` 7085 ("Add GPU Passthrough (Metal) for GitHub-hosted macOS runners", closed 2024-11-29): a maintainer wrote "It is currently impossible due to runners' design". Measured device: "Apple Paravirtual device", `MTLGPUFamilyCommon3` (F9). Runner labels in the docs on 2026-11-03: `macos-15`, `macos-26`, `macos-latest` (macOS 26), `macos-15-intel`, `macos-26-intel`. The label `macos-14` is not in that list.
- llama.cpp itself tests Metal on a self-hosted runner (`ci-self-hosted-metal.yml`: `runs-on: [self-hosted, macOS, ARM64]`) and keeps its `macos-latest` job with test exclusions.
- Recommendation: use a tester Mac with Apple silicon. The gate is the journal, because the app routes the ggml log to it (decision 0065 consequence). Required lines: `GPU family: MTLGPUFamilyApple7` or higher, `has bfloat = true`, `using embedded metal library`, and `loaded in` or `compiled in` with the time. Add a GitHub arm64 job only as a compile check. Use EC2 if no tester Mac exists.

## Open questions (probes not run)

- P1. Does the ARC port (or the `unsafeFlags` exception) compile `ggml-metal-device.m` and `ggml-metal-context.m` with zero warnings in `swift build --arch arm64` and in the two-arch XCBuild build? Probe: copy the files into `Sources/CWhisper`, add the defines of F3, build both ways. Also count the new `-Wshorten-64-to-32` sites.
- P2. Cold and warm time of `ggml_metal_library_init` in embed mode on a base M1 and on macOS 14. Probe: log lines `ggml_metal_library_init: compiled in` and `loaded in`, first and second launch, and after the app moves.
- P3. Stop latency with Metal: run `WhisperEngineBenchmark` with the flag set at 30 % of a 600 s file with large-v3-turbo-q5_0 on the slowest Apple-silicon tester Mac, against the 2 s bound of C10.
- P4. Do the 35 glued texts from the vendoring script compile through `newLibraryWithSource` on macOS 14 and 15 on Apple silicon, and does the `.s` with `.incbin` (or the array file) link under SwiftPM native and XCBuild?
- P5. CPU against Metal transcripts on the C13, C14, C15, and C24 fixtures, for base, small-q5_1, and large-v3-turbo-q5_0, with the same flash-attention setting. Word error rate and the D7 word-end error on both.
- P6. M5 with macOS 14 or 15: does the tensor-API probe of v1.9.5 turn the API off without a crash?
- P7. Does a Metal build run correctly on a Mac with Apple silicon and 8 GB of memory with the turbo-q5_0 model (`recommendedMaxWorkingSetSize`)? whisper.md F19 has no row for it.
- P8. Does the dev Mac (Intel, macOS 15) pass the Metal 3 test? Not needed if F8 holds, but it decides whether a stray Metal start gives wrong output or a hang.

## Claims that no source confirmed

- The ARC port, or `unsafeFlags(["-fno-objc-arc"])`, is the only way past F1. The ARC rule is sourced. "Only" is an inference from the list of `CSetting` options.
- The `.incbin` and the array-file routes of F4 build under SwiftPM.
- The SwiftPM resource accessor for Objective-C does not find a bundle in `Contents/Resources`.
- Native `swift build` warns for unhandled `.metal` files.
- A metallib built without `-mmacosx-version-min=14.0` does not load on macOS 14.
- The x86_64 slice can drop the Metal registration with the `__arm64__` patch only.
- CPU and Metal speed ratios (F16) and the turbo CPU time on Apple silicon.
- The stop latency with Metal is below 2 s on every Apple-silicon Mac.
- The size of the CPU and Metal transcript difference.
- A GitHub larger macOS runner is also virtualized.
- The 593 KB of new source needs more cast sites for the warning rules.

## Sources

- whisper.cpp tag `v1.9.5`, raw files: `ggml/src/ggml-metal/CMakeLists.txt`, `ggml-metal.cpp`, `ggml-metal-device.m`, `ggml-metal-device.cpp`, `ggml-metal-context.m`, `ggml-metal-impl.h`, `ggml-metal-ops.cpp`, `kernels/common.h`, `kernels/dequantize.h`, `kernels/mul_mm.metal`; `ggml/CMakeLists.txt`; `ggml/src/ggml-backend-reg.cpp`; `src/whisper.cpp`; `build-xcframework.sh`. Tree listing: `https://api.github.com/repos/ggml-org/whisper.cpp/git/trees/v1.9.5?recursive=1`. Raw base: `https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/`.
- Vendored tree of this repo: `Sources/CWhisper/` (`src/whisper.cpp`, `ggml/src/ggml-cpu/ggml-cpu.cpp:670`, `ggml/src/ggml-backend-reg.cpp`), `Package.swift`, `Sources/CWhisper/README.dirigible`, `scripts/check-warnings.sh`, `docs/decisions/0034-vendored-c-and-mp3-encoder.md`, `docs/decisions/0065-whisper-transcription.md`, `docs/research/whisper.md`.
- SwiftPM `release/6.2`: `Sources/Build/BuildDescription/ClangModuleBuildDescription.swift`, `Sources/PackageLoading/TargetSourcesBuilder.swift`, `Sources/PackageModel/SupportedLanguageExtension.swift`, `Sources/XCBuildSupport/PIFBuilder.swift`, under `https://github.com/swiftlang/swift-package-manager`.
- Clang, Automatic Reference Counting: `https://clang.llvm.org/docs/AutomaticReferenceCounting.html`.
- Apple documentation JSON: `https://developer.apple.com/tutorials/data/documentation/metal/mtlgpufamily/metal3.json`, `.../apple7.json`, `.../metal/mtllanguageversion/version3_1.json`, `.../version4_0.json`, `.../metal/mtlcompileoptions/languageversion.json`; `https://developer.apple.com/tutorials/data/documentation/xcode/downloading-and-installing-additional-xcode-components.md`.
- whisper.cpp issues: 89 (benchmarks, comments 1327695298, 1401394565, 1414495683, 1476806570, 1493504252, 1742441700, 2827317514), 1692, 1768. Release `v1.7.6`.
- llama.cpp: issue 8617 (comment of 2024-07-22, "Apple Paravirtual device"), pull 19802 (comment 4013704023, 2026-03-06), `.github/workflows/build-apple.yml`, `.github/workflows/ci-self-hosted-metal.yml`.
- `actions/runner-images` issues 7085 and 9254. `github/docs`: `content/actions/reference/runners/larger-runners.md`, `content/actions/reference/runners/github-hosted-runners.md`, `data/reusables/actions/macos-runner-limitations.md`, `data/reusables/actions/supported-github-runners.md`.
- Field reports (third party): `cjpais/Handy` issue 2340; `aethersdr/AetherSDR` pull 4553; `ollama/ollama` issue 14432.
- AWS: `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-mac-instances.html`.
