# 0034. Vendored C code: LAME 4.0 as CLame, warnings fixed at the cause

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after plan gates 1 and 2 of run `2026-10-03-mp3-export`.
- Amends: 0007 (LAME 4.0, not 3.100; the names of the LGPL files), 0019 (MP3 in the format list and the CLI), 0032 (MP3 gets no dither; the LAME level scale).
- Amended: 2026-10-10, run `2026-10-10-episode-metadata`. An MP3 with episode data starts with an ID3v2.3 tag, and the LAME tag frame follows it. An MP3 with no episode data has no ID3 tag, as before (see 0045).
- Amended: 2026-10-11, run `2026-10-11-chapters-in-file`. The ID3 tag also holds one `CTOC` frame and one `CHAP` frame for each chapter of the range. An MP3 with chapters and no episode data has a tag with only these frames. A `CHAP` frame also holds a `WXXX` frame for the chapter URL and an `APIC` frame (type 0) for the chapter image, with the bytes and the type of the file. The `CHAP` times are 32-bit ms, so an export with chapters and a range over 2^32 - 1 ms (about 49.7 days) is refused before any file exists.

## Context

R11 asks for MP3, and 0007 accepts LAME as the static C target `CLame`. Every target treats warnings as errors (SE-0480). Probes of run `2026-10-03-mp3-export` (Intel i5-8259U, macOS 15.7.9, Xcode 26.3, Swift 6.2.4):

- U1. The LAME 3.100 and 4.0 tarballs match the SourceForge hashes. 4.0 (2026-07-11) is the current upstream release, after 3.101 (2026-07-09). The license does not change, and no API is removed. The ticket 500 `frameBits` fix is in the VBR path; the flush buffer-size fix applies to calls with a nonzero buffer size, as ours.
- U2. LAME gives 26 warnings per arch with the SwiftPM flags (`-Wabsolute-value`, `-Wshift-negative-value`, `-Wtautological-pointer-compare`) and 9 more sites with the XCBuild flags of a two-arch build (`-Wshorten-64-to-32`). A 16-line patch in 6 files (casts, literal types, and the always-true `pTagData->toc != NULL` check of `GetVbrTag` in `VbrTag.c` removed) gives 0 warnings on both paths, for arm64 and x86_64. `treatAllWarnings(as: .error)` in `cSettings` gives `-Werror` on both paths.
- U3. Core Audio reads the LAME tag: the decoded length equals the input length at 48 kHz, and at 44.1 kHz with 64, 128, 192, or 256 kbit/s, after the LAME resampler too. At 44.1 kHz with 96 or 160 kbit/s, and in some 1 s files at 32 kHz, Core Audio often reads one frame (1152 samples) more; the tag is correct, and ffmpeg and mpg123 read the exact length (probe len96). LAME with an out rate of 96 kHz writes 48 kHz with no error.
- U7. At 22.05 kHz LAME lowers 256 kbit/s to 160 kbit/s with no error. At 32, 44.1, and 48 kHz it keeps 256.
- U4. A sine reads 0.45 dB lower at 64 to 160 kbit/s, 0.26 dB lower at 192, and equal at 256: LAME scales its input against clipping.
- U5. 2 h of stereo at 128 kbit/s encodes in 60 s at `-Os`.
- U8. With the asserts on, held values and noise to 1e4 encode; 1e6, 1e30, NaN, and infinity abort on an assert.

## Decision

- **Source.** `Sources/CLame` holds `libmp3lame` of LAME 4.0 (SHA-256 `3df5124d…216eb`): the encoder files, their headers, `include/lame.h`, and our `config.h` (no `TAKEHIRO_IEEE754_HACK`: LAME tests it with `#ifdef`). No decoder (`mpglib_interface.c` and `mpglib/` are out), no frontend, no SSE path. `README.dirigible` names the source, its hash, and each changed file.
- **Warnings.** A warning in vendored C code is fixed at its cause in the vendored file, with no change of behavior: casts, literal types, and one always-true array check removed. No API is removed. Each changed file has a dated notice line (LGPL-2.0 section 2(b)). `CLame` has `treatAllWarnings(as: .error)` in `cSettings`. `check-warnings.sh` requires that setting for each target with a `.c` file and refuses `disableWarning`, `treatWarning`, and `unsafeFlags`.
- **Asserts.** The LAME asserts stay on in release builds, as in the LAME build. The known trigger is a non-finite or very large sample: the export sets each NaN or infinite sample to 0 and clamps each finite sample to ±64 before the encode.
- **Init.** One process-global call of `lame_close(lame_init())` fills the global log table before the first MP3 export. The four globals that each `lame_init_params` writes with no lock get the same values each time; that race is accepted. A debug build (SwiftPM defines `DEBUG`) also writes the static `hogege` of `bitstream.c` with no lock, only for a debug print that the export turns off; that race is accepted too, and it changes no output.
- **Encoder.** `ExportFormat.mp3(BitRate)`: CBR at 64, 96, 128, 160, 192, or 256 kbit/s (default 128), joint stereo or mono, LAME quality 3, the LAME tag at the file start, no ID3 tag. The rate is the session rate, 44.1, or 48 kHz; a file rate other than 32, 44.1, or 48 kHz throws `.rateNotSupported` before any file exists. After the LAME setup, an out rate or a bit rate other than the asked one also throws `.rateNotSupported`; a refused setup throws `.writeFailed(kAudio_ParamError)`. LAME changes the rate. No dither. The export report is the measure of the decoded file (0032). The search starts the limited signal up to 0.45 dB higher (U4), and the read-back replaces that offset with the measured change.
- **License files.** `Contents/Resources/LAME-COPYING.txt` (the LAME `COPYING`) and `LAME-NOTICE.txt`. `bundle.sh` adds the line `Source commit: <hash>` (the HEAD commit, with `, with uncommitted changes` for a changed tree) to the bundled notice, so the notice points to the source of the shipped binary. `AppBundleTests` checks both files and the 40-hex commit.

## Consequences

- A LAME update reapplies the patch of `README.dirigible`. The MP3 level and loudness tests pin the LAME scale table (U4): after an update, measure the scale again before you look for a bug.
- A new Xcode can add a default warning that breaks the CLame build. The fix goes into the vendored file.
- An assert failure in LAME aborts the app, also a take in another window.
- `dirigible` links LAME too. It ships only as source (0011), so it needs no license file.

## Alternatives considered

- Pristine source with `disableWarning`: rejected, it hides warnings.
- `unsafeFlags(["-w"])`: rejected, it hides all warnings.
- A prebuilt static library: rejected, a binary in git and a harder relink.
- A dynamic library: rejected, 0007 accepted static, and the public source allows a relink.
- LAME 3.100: rejected. 4.0 is the current upstream release with the same license and no API removal. The ticket 500 fix is in the VBR path; the flush buffer-size fix applies to our calls.
