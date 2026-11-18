# Waveform sync of a clip to another track (F74)

Date: 2026-10-28

This file gives the facts for the F74 plan. Landing 1 aligns one clip to one track with one offset. Landing 2 aligns an outside recording that has its own clock: offsets at several points, a robust line fit of offset and rate, and one resample.

Marks used in this file:

- "unconfirmed": no primary source states the claim.
- "Inference:": our reading of the sources. Each Inference names a case that it was not checked against.
- "(snippet)": the source was not readable by the tool (HTTP 403 or script page). The claim comes from a search-result summary of that page. Read the page before you rely on it.

The machine for all cost numbers: MacBookPro15,2, Intel Core i5-8259U, 2.3 GHz, 8 logical CPUs (`sysctl hw.model`, `hw.ncpu`, `machdep.cpu.brand_string`). Python on this machine has no numpy. No FFT throughput was measured. A push check held the build lock, so no C or Swift probe ran.

## Part 1. Reference apps

### Finding 1. Final Cut Pro: Synchronize Clips

- Entry point: Clip > Synchronize Clips (Option-Command-G) [FCP-SYNC]. The user selects the clips in the browser. There is no "reference" clip to choose.
- Result: a new synchronized clip in the event that the user names. "The original clips are not affected." Source clips are hidden by default [FCP-SYNC]. The page does not say "compound clip" in the part that the tool read. The multicam page says the option syncs video and audio clips "into a compound clip" [FCP-AUTO].
- Method: FCP analyzes clips for markers, timecode, file creation date, and audio content. "If no sync points can be found, the clips are synced at their respective starting points" [FCP-SYNC]. So a failure does not raise an error. The clips stay at their starts.
- Audio option: "Use audio for synchronization" "makes precision sync adjustments using audio waveforms" [FCP-SYNC]. It is a checkbox on top of the other sync points.
- Limits and failure text: "Some audio recordings are not suited for use with this feature." The option "may result in long processing times during which Final Cut Pro is not available for editing" [FCP-SYNC].
- Accuracy: no number in the page. Drift: the page does not mention it (the tool saw a truncated page; unconfirmed whether a later section covers drift). `docs/research/final-cut-pro.md` section 7 holds the same facts and says that no source states drift correction.

### Finding 2. DaVinci Resolve: Auto Sync Audio

- Entry point: select a video clip and its audio clip in the media pool, right-click, Auto Sync Audio > Based on Waveform, or Based on Waveform and Append Tracks [FRAMEIO]. The video and audio files must be in the same bin [FRAMEIO].
- Result: a synced clip. The camera audio is replaced by the sync audio. The append variant keeps both [FRAMEIO].
- Failure: "you may see a notice that some clips couldn't be synced" [FRAMEIO]. The exact text is not quoted there.
- Needs: a scratch audio track in the video [FRAMEIO]. Waveform sync is slower than timecode sync, no times given [FRAMEIO].
- Channel choice (Auto, Mix, one channel) comes from two third-party guides read through a search summary (snippet) [RESOLVE-GUIDES]. The Blackmagic reference manual was not readable (PDF host returned 403). Accuracy and drift handling: unconfirmed.

### Finding 3. PluralEyes (Red Giant, now Maxon)

- Needs: "at least 5 to 10 seconds of good quality audio content" per clip. It cannot sync silent video. Discontinuous clips must be trimmed so each clip is continuous. Clips from a time when only one device recorded may not sync [MAXON-PE].
- Failure: a small share of clips stays unsynced. The user fixes them by hand in the editor [MAXON-PE].
- Drift: "Correct Audio Drift" is on by default. "When drift is detected in an audio clip, the sync is stopped." The tool creates a new audio file for each corrected original [MAXON-PE]. A launch article says that PluralEyes 3.5 makes the whole track correct, then restarts the sync from the start (snippet) [PE-LAUNCH].
- Accuracy: no number in the help page. A launch article claims "frame-accurate" sync (snippet, marketing) [PE-LAUNCH]. "Try Really Hard" does not appear in the Maxon help page. Unconfirmed that the option exists.

### Finding 4. Adobe Premiere Pro

- Merge Clips and Synchronize (timeline) use In or Out points, timecode, or markers. The Adobe pages list no waveform option for them. "Auto-sync from audio waveforms is not supported for merged clips" (snippet) [PREMIERE-SYNC].
- The multicam source sequence dialog has an "Audio" sync option that syncs by an audio track (snippet) [PREMIERE-MC]. Both Adobe pages returned HTTP 403. Failure text, accuracy, and drift: unconfirmed.

### Finding 5. Hindenburg PRO

- No waveform sync or audio alignment feature was found. The Hindenburg Academy guide index lists Link Tracks, Insert Special, Remote Interview, and Clipboards, and no sync entry [HB-GUIDES]. The PRO manual URL tried returned 404. A search of hindenburg.com found only an unrelated "aligned" voice-profile text (snippet).
- Absence of the feature is unconfirmed. The index is a list of videos, not the manual.

### Finding 6. Audacity

- No waveform-based alignment. Tracks > Align Tracks has Align End to End, Align Together (same start time), Start to Zero, and cursor or selection commands. Alignment by eye uses the Time Shift tool [AUDACITY-ALIGN].

### Finding 7. Auphonic Multitrack

- Auphonic does not align tracks. "All tracks are mixed in parallel and must start at the same time." The user adds silence in front of a track that starts late [AUPHONIC-TIPS]. The multitrack algorithm page says nothing on time alignment, delay compensation, or drift [AUPHONIC-MT]. The API has a per-track offset in seconds set by the caller (snippet) [AUPHONIC-API].

### Finding 8. Double Ender (The Incomparable), a macOS utility for the exact use case

- Entry: the user opens the local recordings and one reference file "that contains all voices together". Double Ender "syncs local audio recordings to a reference file so they all start at the same moment and stay in sync" [DOUBLEENDER].
- Result: mono WAV files with the originals untouched. The output sample rate follows the reference file [DOUBLEENDER].
- Drift: if the recording rates differ, the app "patches or removes areas of silence to offset the drift". It does not resample [DOUBLEENDER]. Version 1.6 scans the whole file so that a sync error over 30 minutes or more "should be caught" [DOUBLEENDER]. Version 1.7 merges several sequential recordings of one person into one file [DOUBLEENDER].
- Accuracy and failure display: not documented.
- Inference: this is the closest shipped product to landing 2. It uses the gap/patch model (one fit per segment), not a resample. Not checked against: a recording that is stretched, not only shifted.

### Finding 9. Riverside, Descript, Pro Tools, Logic

- Riverside: the support page describes manual lip-sync nudges in 50 ms steps (snippet) [RIVERSIDE]. No source says that it auto-aligns a guest recording. The page returned HTTP 403.
- Descript: nothing found. Unconfirmed.
- Pro Tools and Logic Pro: no built-in waveform sync found. Synchro Arts VocALign (plug-in and standalone) aligns one audio signal to another for Pro Tools 7 or higher and Logic 8 or higher (snippet) [VOCALIGN].
- Cubase has an Audio Alignment panel (snippet) [SOS-CUBASE].

### Finding 10. What the apps have in common (Inference)

- Inference: every app moves or wraps the clip and keeps the source. The failure signal is weak: FCP falls back to the start points, Resolve and PluralEyes list unsynced clips. No app shows a confidence number. Not checked against: the Resolve manual and the Premiere audio sync dialog, which were not readable.
- Only PluralEyes (resample, whole track, restart the sync) and Double Ender (patch silence) document drift handling.

## Part 2. Algorithm

### Finding 11. Cross-correlation, normalization, and the FFT

- The search for an offset is "the lag that maximizes the cross-correlation" in a window, computed by an exhaustive search over a bounded lag range [-L, L] chosen "based on our experience of the largest offsets encountered" [RAFFEL]. The paper uses the unbiased cross-correlation [RAFFEL].
- FFT method: the product of one spectrum and the conjugate of the other, then an inverse FFT, gives all lags at once. Source for the FFT identity: none fetched (textbook knowledge). The Apple header supports the building blocks (finding 27). Treat the identity as Inference: not checked against: very different input lengths.
- Normalized cross-correlation (division by the local energy of the long signal) is not described by any source that the tool read. Unconfirmed. Use it only if the level of the two signals differs a lot over the window.

### Finding 12. GCC-PHAT

- Reference: C. H. Knapp and G. C. Carter, "The Generalized Correlation Method for Estimation of Time Delay", IEEE Trans. ASSP, vol. ASSP-24, no. 4, pp. 320 to 327, Aug 1976 [MATHWORKS-GCC]. The paper itself was not readable by the tool.
- Method: PHAT "normalizes the signal spectral density with the spectrum magnitude". The ideal result is a delta at the delay [MATHWORKS-GCC]. Delays are "quantized to the nearest sample interval" [MATHWORKS-GCC].
- Why it helps on reverberant signals: secondary sources call it a robust prefilter in reverberant rooms (snippet) [WEB-GCC]. One secondary source says GCC-PHAT degrades when noise rises (snippet) [WEB-GCC].
- Why it helps on speech or on a codec-degraded copy: no source found. Unconfirmed. Inference: whitening removes the spectral shape (filter, EQ, codec band limit), so the peak depends on phase alone. Whitening also raises the weight of bins where only noise or codec artifacts exist, so limit the band (for example 300 Hz to 3.4 kHz) before you whiten. Not checked against: a real Zoom or Teams copy. Probe that on real files.

### Finding 13. Feature-based methods

- BBC audio-offset-finder: "cross-correlation of standardised Mel-Frequency Cepstral Coefficients", meant to be tolerant of encoding and compression noise. Accuracy "typically within about 0.01 s". Default analysis rate 8000 Hz. Default step 128 samples (0.016 s). "Trim" keeps the first n seconds and must be at least twice the maximum offset [BBC-AOF].
- Kammerl et al., ICASSP 2014 (Florence). The author list is Kammerl, Birkbeck, Inguva, Kelly, Crawford, Denman, Kokaram, Pantofaru. The method builds a graph from pairwise audio cross-correlations of many recordings. A Minimum Spanning Tree or Belief Propagation resolves outlying pairs. "Spectral flatness performs better than zero-crossing rate and signal energy" as the feature [KAMMERL]. This paper is about N-way sync, which F74 does not need. Only the feature result applies.
- Shrestha, Barbieri, Weda, "Synchronization of multi-camera video recordings based on audio", ACM Multimedia 2007, pp. 545 to 548. Only the citation was confirmed [DBLP-SHRESTHA]. The ACM page redirected and the method text was not read. Unconfirmed.

### Finding 14. Coarse to fine

- BBC AOF resamples to 8 kHz and steps by 128 samples. That is a coarse search with a stated precision limit [BBC-AOF]. Raffel and Ellis first fix the global resampling ratio, then estimate local offsets [RAFFEL].
- No source describes an envelope at 1 kHz or 2 kHz followed by a fine search at a high rate. Inference: a two-stage search works because the coarse stage only has to land inside the peak width of the fine stage. Not checked against: a 1 kHz envelope of music with strong beats, where several lags of one beat period score close to each other.

### Finding 15. Sub-sample peak interpolation

- DXCP (Chinaev, Thune, Enzner) applies "a parabolic maximum search" around the correlation maximum to get a real-valued delay [DXCP-ARXIV]. Yamaoka et al. (EUSIPCO 2021) replace it by an iterative maximization and report better results (snippet) [EUSIPCO21].
- GCC-PHAT peak locations are "restricted to multiples of the sample interval" without an interpolation step [MATHWORKS-GCC].
- Inference: fit the parabola through the peak sample and its two neighbors. Not checked against: a PHAT peak that is a narrow spike, where the parabola can be biased. Check the bias on a synthetic fractional delay.

### Finding 16. Confidence for "no match"

- BBC AOF "standard score": a score "greater than ten is likely to be correct"; "below five" is unlikely to be correct. "The score depends on the length of the audio analysed", so the thresholds are rough [BBC-AOF]. The README says that a single well-defined peak in the correlation plot indicates a likely correct offset [BBC-AOF].
- Peak-to-sidelobe ratio (PSR) is the peak minus the mean of the sidelobes, divided by their standard deviation (snippet) [PSR-SNIPPET]. No numeric threshold was confirmed (the original Bolme et al. CVPR 2010 PDF could not be read as text). Thresholds of PSR in audio: unconfirmed.
- Peak to second peak ratio: no source gives a threshold. Unconfirmed.
- Inference: use the BBC standard-score definition (peak minus the mean, divided by the standard deviation of the correlation outside a guard zone around the peak). Start with 10 for accept and 5 for reject, and tune on real files. Not checked against: a short window with a 10 s clip, where the score is lower for the same quality.

## Part 3. Drift

### Finding 17. Size of the clock error

- Consumer crystals: "typically rated at plus or minus 20 to 50 ppm". Two devices can differ by up to about 100 ppm. 50 ppm gives 180 ms over one hour [FORASOFT] (a vendor blog, secondary).
- Raffel and Ellis: separate devices "will frequently differ by several hundred parts per million, depending on the quality of the quartz oscillators used", which "can amount to drifts of a second or more" [RAFFEL]. They search the resampling ratio in [0.9999, 1.0001] (plus or minus 100 ppm) for their data [RAFFEL].
- An old audio-codec note asks for crystals within plus or minus 100 ppm (snippet) [ADI-AC97].
- Apple: for a Core Audio aggregate device "even devices with the same sample rate may occasionally correct because of individual device clock timing drift" (snippet) [APPLE-AGG].
- A call track from Zoom or Teams is not a pure clock case. WebRTC NetEq "changes playout speed to time stretch (accelerate or decelerate)" the audio when the jitter buffer drifts [NETEQ]. Unconfirmed whether Zoom or Teams use NetEq or the same method. Inference: a call track can have non-linear time stretch on top of the clock error. Not checked against: a real call recording.
- Search range for the rate: Inference: accept a rate error of plus or minus 500 ppm (above the "several hundred" statement) and treat a larger value as a failed fit.

### Finding 18. How sources estimate drift

- Raffel and Ellis model the offset as piecewise linear. Step 1: a global resampling ratio by a linear grid search near 1 (the problem is non-convex). Step 2: local offsets from windowed cross-correlation at regular intervals, then linear interpolation between them. In their remix experiment: "local offsets every 1 second by computing the cross-correlation over 4 second windows with a maximum allowable offset of 100 ms" [RAFFEL]. They apply the correction with windowed-sinc interpolation [RAFFEL].
- DXCP (online, for microphone arrays at 16 kHz): the sampling-rate offset equals the drift difference between two frames divided by the frame distance. The frame distance is Lb times Ns samples (39 times 2048). The estimator has a linear range of about 12.5 ppm and a steady-state bias of about 1 ppm [DXCP-ARXIV]. It is an online tracker. It needs far less memory than a batch fit but has a small range.
- PluralEyes: stops at the first clip that shows drift, resamples the whole track, and restarts [MAXON-PE] [PE-LAUNCH].

### Finding 19. Robust line fit

- scikit-learn documentation: RANSAC, Theil-Sen, and Huber regression. "When in doubt, use RANSAC." RANSAC copes best with large outliers in y. Theil-Sen has a breakdown point of about 29.3% for a simple linear regression. Huber down-weights outliers (epsilon 1.35 for 95% efficiency) and does not reject them. Theil-Sen cost grows combinatorially with the sample count [SKLEARN].
- Inference: with 10 to 60 windows, Theil-Sen on all pairs costs at most about 1800 slopes and needs no random numbers (the result is repeatable). A 29.3% breakdown fits a track where up to a quarter of the windows are dropouts. A two-step method (Theil-Sen, then drop points with a residual above a threshold, then a least-squares refit on the inliers) is common practice. Not checked against: a track where more than 30% of windows fail, for example a call with long silence.

### Finding 20. Windows: length and count

- Sources use a 4 s window every 1 s (Raffel and Ellis, music) [RAFFEL] and a 128 ms frame shift with a 39-frame distance (DXCP) [DXCP-ARXIV]. No source gives a count for a 1 to 3 hour speech recording. Unconfirmed.
- Arithmetic: 50 ppm moves the signal by 1.5 ms in a 30 s window and by 0.5 ms in a 10 s window. 100 ppm moves it twice that. The correlation peak widens by that amount.
- Inference: use windows of 10 to 20 s, spread evenly over the clip, at least 8 windows and about one per 2 to 3 minutes. Skip a window in which one side is silent (energy test). Not checked against: a very sparse guest who speaks in short bursts. For such a track pick windows by energy, not by position.

### Finding 21. Is a linear model enough for 1 to 3 hours

- Raffel and Ellis: the main cause is the recorder clock, "a predominantly linear function", so they model it as piecewise linear [RAFFEL]. Temperature drift of crystals over hours: no source read. Unconfirmed.
- Inference: a line is enough when the residuals of the inlier windows stay under about 1 ms. A residual that bends (for example a curve or a step) means a pause, a gap, a call dropout, or a non-linear clock. Then split the clip into segments and fit one line per segment (the landing 2 edge case "pause or gap"). Double Ender takes the same view with patch and remove-silence (finding 8). Not checked against: a 3 hour recording on a laptop that warms up.

## Part 4. Cost

### Finding 22. Sizes and memory (arithmetic, no source)

All numbers are float32 (4 bytes per sample). A linear (not circular) correlation of two signals of N samples needs an FFT length of at least 2N minus 1, rounded up to a power of two.

| Case | Samples per track | FFT length | One real buffer | Flops of one real FFT (2.5 N log2 N) |
|---|---|---|---|---|
| 1 h, 48 kHz, full rate | 172.8 M | 2^29 (537 M) | 2.15 GB | 3.9e10 |
| 3 h, 48 kHz, full rate | 518.4 M | 2^31 (2.15 G) | 8.6 GB | 1.7e11 |
| 1 h, 2 kHz envelope | 7.2 M | 2^24 (16.8 M) | 67 MB | 1.0e9 |
| 3 h, 2 kHz envelope | 21.6 M | 2^26 (67.1 M) | 268 MB | 4.4e9 |
| 1 h, 1 kHz envelope | 3.6 M | 2^23 (8.4 M) | 34 MB | 4.8e8 |
| 3 h, 1 kHz envelope | 10.8 M | 2^25 (33.5 M) | 134 MB | 2.1e9 |
| 30 s window at 8 kHz, plus 2 s of lag range each side | 240 k plus 32 k | 2^19 (524 k) | 2.1 MB | 2.5e7 |
| 30 s window at 48 kHz, plus 1 s of lag range each side | 1.44 M plus 96 k | 2^21 (2.1 M) | 8.4 MB | 1.1e8 |

- The two window rows use circular correlation with the FFT length set to the longer signal plus the lag range. The lags inside the range equal the linear result. With a bounded user offset (finding 24), the full-rate rows need only N plus the maximum offset, so the 1 h full-rate row can drop to 2^28 (a 1.07 GB real buffer).
- The flop convention comes from FFTW: "mflops = 2.5 N log2(N) / time" for real transforms [FFTW]. One correlation needs three real FFTs (two forward, one inverse), so multiply by 3.
- The full-rate one-shot correlation needs a buffer of 2 GB (1 h) or 8.6 GB (3 h) per signal, and two signals. It is not a good design on the slowest target. The tables show that the envelope route costs under 0.3 GB.
- Direct `vDSP_conv` for the 1 kHz envelope of 1 h with a lag range of plus or minus 60 s (120 000 lags) is 3.6 M times 120 000 = 4.3e11 multiply-adds. That is far more than the FFT route (1.4e9 flops). Use direct correlation only for short windows with a small lag range.
- Arithmetic check of the rate: 48 000 Hz times 3600 s = 172.8 M samples. 1 000 Hz times 10 800 s = 10.8 M samples.

### Finding 23. Time on this machine

- Not measured. numpy is not installed (`ModuleNotFoundError`). A C probe of `vDSP_fft_zrip` at log2n 20 to 26 did not run. See Open question 3.
- Inference, with a stated assumption of 1 GFlop/s for large, memory-bound FFTs on the i5-8259U: one 2^25 real FFT takes about 2 s. One correlation of a 3 h, 1 kHz envelope takes about 6 s. A 30 s window at 48 kHz takes about 0.3 s, so 20 windows take about 6 s. The 1 GFlop/s figure has no source. Replace it with the probe result.

### Finding 24. Search range limits

- BBC AOF: the offset must be "somewhat less than" the trim, and the trim should be at least twice the maximum expected offset [BBC-AOF]. Raffel and Ellis limit local lags to 100 ms around the global fit [RAFFEL].
- Inference for F74: the user states a maximum offset (default a few minutes for a late-started guest recording). The coarse stage searches plus or minus that value on the 1 kHz envelope. Its cost is set by the clip length, not by the offset. The fine stage searches only plus or minus the coarse peak width (for example 50 ms). Landing 2 windows search plus or minus the drift left after the first fit (for example plus or minus 100 ms). Not checked against: a guest file that starts after the host file by more than the user range. That case must report "no match", not guess.

## Part 5. Apple APIs

All header facts come from the local SDK (Xcode with the macOS 26 SDK): `Accelerate.framework/.../vecLib.framework/Headers/vDSP.h`, `usr/lib/swift/Accelerate.swiftmodule/x86_64-apple-macos.swiftinterface`, `AudioToolbox.framework/Headers/AudioConverter.h`, `AVFAudio.framework/Headers`. The online Apple documentation pages render only a title for the tool, so they were not used.

### Finding 25. `vDSP_conv` and `vDSP.correlate` (direct)

- `vDSP_conv(A, IA, F, IF, C, IC, N, P)` computes `C[n] = sum(A[n+p] * F[p], 0 <= p < P)`. "Commonly, this is called correlation if IF is positive and convolution if IF is negative" [VDSP-H]. Cost is N times P. Available since macOS 10.0 [VDSP-H].
- Swift overlay `vDSP.correlate(_:withKernel:)` (Float and Double) is available from macOS 10.15 [SWIFTINTERFACE]. It calls `vDSP_conv` with stride 1. The input must hold at least `result.count + kernel.count - 1` samples. The variant that returns an array allocates `vector.count - kernel.count` results, one fewer than the maximum. Call the `result:` variant with your own count if you need all lags [SWIFTINTERFACE].
- Fit: short windows only (finding 22).

### Finding 26. Real FFT, DFT, and the packed format

- `vDSP_DFT_zrop_CreateSetup(previous, length, direction)`: "Length must be even". Implemented lengths: `2**n`, and `f * 2**n` with f = 3, 5, or 15 and 4 <= n. It returns zero (NULL) if the case is not implemented [VDSP-H]. Available from macOS 10.7 [VDSP-H]. The header recommends the DFT routines over the older FFT routines ("We suggest you use the DFT routines instead") [VDSP-H].
- Forward DFT scale: `C` is 2 for forward and 1 for inverse in `vDSP_DFT_Execute` [VDSP-H]. With the inverse scale of 1 and no 1/N, a forward then inverse round trip gains 2N. Inference from the formula in the header. Check it with the probe (Open question 1).
- `vDSP_fft_zrip(setup, split, stride, log2n, direction)`: forward scale is 2. The header gives the inverse scale as `1/N` [VDSP-H]. The header of the two families differs in form. Do not assume the round-trip gain. Measure it once in a unit test (Open question 1). The scale does not change the position of a peak, only the value of a normalized peak.
- Packed layout of both: the real input is coerced into split complex (`h[2j]` in `realp[j]`, `h[2j+1]` in `imagp[j]`). The output stores DC in `realp[0]` and Nyquist in `imagp[0]`. Bins 1 to N/2 - 1 are regular complex. The other half is the conjugate [VDSP-H].
- Bug to avoid: a complex multiply over all N/2 packed values treats element 0 as the complex number DC + i times Nyquist. That is wrong. Multiply bins 1 to N/2 - 1 as complex. Multiply bin 0 as two real products: `realp[0] = a.realp[0] * b.realp[0]` and `imagp[0] = a.imagp[0] * b.imagp[0]`. Inference from the layout above. Check it on a known delay (Open question 1).
- `vDSP_create_fftsetup(log2n, radix)` exists since macOS 10.0. The header gives no maximum log2n for `vDSP_create_fftsetup`. The maximum is unconfirmed (Open question 2). The setup is created for a given maximum log2n and can serve smaller sizes. The newer DFT setup "may not be used to execute transforms with shorter lengths" [VDSP-H].
- Swift: `vDSP.FFT(log2n:radix:ofType:)` has `forward(input:output:)` and `inverse(input:output:)` on `DSPSplitComplex` (macOS 10.15). `vDSP.DFT` is deprecated since 10.15 in favor of `vDSP.DiscreteFourierTransform` (macOS 12, throwing init). `init(previousDFT:...)` needs macOS 26 [SWIFTINTERFACE].

### Finding 27. Complex multiply, peak search, magnitude

- `vDSP_zvmul(A, IA, B, IB, C, IC, N, Conjugate)`: "If Conjugate is -1: C[n] = conj(A[n]) * B[n]" and +1 gives `A[n] * B[n]` [VDSP-H]. For `IFFT(conj(X_ref) * X_target)` the cross-correlation `r[k] = sum a[n] b[n+k]` has its peak at the lag k where the target is later than the reference. Inference from the definition. Check the sign with a known delay (Open question 1).
- `vDSP_maxvi(A, IA, &C, &I, N)`: "I[0] is set to the least i*IA such that A[i] has the value in C[0]" [VDSP-H]. So the index is multiplied by the stride, and a tie gives the lowest index. Swift: `vDSP.indexOfMaximum` returns `(UInt, Float)` from macOS 10.15 [SWIFTINTERFACE]. For the search of a peak inside a lag window, run it on the slice of the lags.
- PHAT needs the magnitude of each bin. The header declares `vDSP_zvmags` (squared magnitude of split complex, macOS 10.4), `vDSP_zvabs` (magnitude), `vDSP_zvdiv`, and `vDSP_vdiv` (note the swapped A and B arguments: "Caution: A and B are swapped!"). vForce declares `vvrsqrtf` (macOS 10.4) [VDSP-H] [VFORCE-H]. Inference: `vDSP_zvmags`, then `vvrsqrtf`, then a scale of the real and imaginary parts by that value. Not checked against: the zero-magnitude bins, which need a small floor to avoid division by zero, and the packed bin 0.

### Finding 28. Decimation with `vDSP_desamp`

- `vDSP_desamp(A, DF, F, C, N, P)`: "Anti-aliasing down-sample with real filter". `C[n] = sum(A[n*DF + p] * F[p], 0 <= p < P)` [VDSP-H]. Available since macOS 10.4. Swift: `vDSP.downsample(_:decimationFactor:filter:)` from macOS 10.15 [SWIFTINTERFACE].
- The caller designs the filter. The function has no design step. Inference: input length must be at least `(N - 1) * DF + P`. Not checked against: the exact bounds check in the header.
- A decimation factor must be an integer. 44.1 kHz to a round analysis rate is not an integer factor. Convert both files with `AVAudioConverter` first (finding 29).

### Finding 29. Resample for 44.1 to 48 kHz and for a drift ratio

- The repo already uses `AVAudioConverter` with `sampleRateConverterQuality = AVAudioQuality.max.rawValue` and `sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal` in `Sources/DirigibleAudio/Finalize/ClipConversion.swift` (lines 125 and 126).
- `AudioConverter.h`: complexity options Linear (`'line'`), Normal (`'norm'`, default), Mastering (`'bats'`), MinimumPhase (`'minp'`). Quality constants: Max 0x7F, High 0x60, Medium 0x40, Low 0x20, Min 0. MinimumPhase "High is several times faster than Mastering Low", with a noise floor of -160 dB at High [AUDIOCONVERTER-H]. Initial phase is a Float64 in [0, 1) [AUDIOCONVERTER-H].
- Fractional source rate: `AVAudioFormat` takes `sampleRate` as `double` [AVAUDIOFORMAT-H], and `AudioStreamBasicDescription.mSampleRate` is a `Float64`. So `48000 * (1 + 50e-6) = 48002.4` can be written in a format. No header says that the converter honors a non-integer ratio exactly, or that `AVAudioFormat` accepts a non-standard rate. Unconfirmed (Open question 4).
- Option: `AVAudioUnitVarispeed.rate` is a Float and "resamples the input signal" and "changes the pitch" [VARISPEED-H]. That is the right model for a clock error. A Float holds 1.00005 with 1e-7 resolution. Quality and offline use are unconfirmed.
- Option: do the resample with own code (a windowed-sinc interpolation, as Raffel and Ellis do [RAFFEL]) in the segment loop. No Apple routine was verified for it.
- Inference: for landing 2, set the source format rate to `nominal * (1 + epsilon)` and the destination to the project rate, if the probe in Open question 4 shows an exact ratio. Otherwise use the own interpolation. Not checked against: a 3 hour file, where a ratio error of 1e-9 moves the end by 0.5 ms.

## Recommended default

This section rests on the findings named in brackets.

**Landing 1 (one offset).**

- Features: both tracks to mono, then to 8 kHz with `AVAudioConverter` [29]. Band 300 Hz to 3.4 kHz [12].
- Coarse stage: log-energy envelope at 1 kHz [14, 13], zero-mean, FFT cross-correlation over plus or minus the user's maximum offset [11, 24]. FFT length from the table [22]. Peak by `vDSP_maxvi` [27].
- Fine stage: GCC-PHAT on the 8 kHz band-limited signals in a window of 20 to 30 s around the coarse peak, search plus or minus 50 ms [12, 14, 24]. Parabolic interpolation of the peak [15]. Final offset in samples at the project rate, rounded to a sample.
- Confidence: BBC-style standard score (peak minus the mean, divided by the standard deviation outside a guard zone) [16]. Accept at 10 or higher. Reject below 5. Ask the user between 5 and 10 [16]. Report "no match" and leave the clip in place on a reject, as FCP does [1, 10]. The thresholds are Inference and need tuning on real files.
- Cost: under 1 GFlop for 1 h, 6 GFlop for 3 h at the 1 kHz stage [22]. Time on this machine is unconfirmed [23].

**Landing 2 (offset and rate).**

- Windows: 10 to 20 s, at least 8, about one per 2 to 3 minutes, chosen where both sides have energy [20]. Each window runs the landing 1 fine stage with a search of plus or minus 100 ms around the first estimate [18, 24].
- Outlier rejection: drop windows with a score under 5 [16]. Fit offset against time with Theil-Sen, drop points with a residual above 1 ms (Inference), refit by least squares on the inliers [19]. Accept a rate error up to 500 ppm [17]. Need at least 5 inliers and 60% of the windows (Inference).
- Segments: if the residuals bend or step, split at the largest step and fit one line per segment [21, 8].
- Resample: one resample of the guest track by the fitted ratio [3, 29]. Quality: Normal complexity at max quality, as `ClipConversion.swift` does today [29].
- Rates: both files go through the analysis rate converter, so 44.1 and 48 kHz need no special case [28, 29]. The fitted ratio is then relative to the nominal ratio of the two rates.
- Call track with a codec-degraded copy: use the band limit and the envelope stage [12, 13]. Test on a real Zoom and Teams file (Open question 5).
- Several remote people in one call track: no source found. Unconfirmed. Inference: correlate against the host's clean mic as the reference per voice, and let the score decide. Not checked against: a track where two guests speak at once.

**API list.** `AVAudioConverter` (rate change, quality max, Normal), `vDSP.DiscreteFourierTransform` or `vDSP_DFT_zrop_CreateSetup` with `vDSP_DFT_Execute` (real FFT, lengths `2^n`) [26], or `vDSP_fft_zrip` with `vDSP_create_fftsetup` [26], `vDSP_zvmul` with conjugate -1 [27], `vDSP_maxvi` or `vDSP.indexOfMaximum` [27], `vDSP.correlate` or `vDSP_conv` for short windows only [25], `vDSP_desamp` only for an integer factor [28]. Handle packed bin 0 apart [26].

## Open questions

These need a Swift or C probe on the Intel Mac.

1. Round-trip gain of `vDSP_fft_zrip` and of `vDSP_DFT_Execute` (forward then inverse), and the sign of the peak for `vDSP_zvmul(..., -1)` with a known delay. The header and the common lore disagree on the scale (finding 26).
2. The largest log2n that `vDSP_create_fftsetup` and `vDSP_DFT_zrop_CreateSetup` accept (try 20 to 31), and the memory use at 2^26.
3. Time of one real forward FFT at log2n 20 to 26 on the i5-8259U, and the GFlop/s. Replace the 1 GFlop/s assumption of finding 23.
4. Whether `AVAudioConverter` honors a source rate of 48002.4 Hz as an exact ratio (check the output length and a 1 kHz tone at the end of 3 hours), and whether `AVAudioFormat` accepts it. Compare with `AVAudioUnitVarispeed` in offline manual rendering mode and with own interpolation.
5. GCC-PHAT against envelope correlation on real material: a clean mic against a Zoom copy and a Teams copy, speech with silence, music. Measure the offset error, the standard score, and the peak to second peak ratio. Set the thresholds from that data.
6. Several remote people in one call track: the score per voice and the failure case.
7. Whether a call track from Zoom or Teams has non-linear time stretch (finding 17). Fit a 2 h call and look at the residuals.
8. Whether a PHAT weight made with `vDSP_zvmags` and `vvrsqrtf` keeps enough precision in float32 for a 2^21 bin spectrum with near-zero bins (finding 27).

## Sources

- [FCP-SYNC] Apple, Sync audio and video in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/verc1fabc30/mac
- [FCP-AUTO] Apple, Final Cut Pro automatic audio sync: https://support.apple.com/guide/final-cut-pro/automatic-audio-sync-ver8798d940/mac (page text read through a fetch of the "aside" page; the same statements as FCP-SYNC)
- [FRAMEIO] Frame.io blog, Why DaVinci Resolve is the Ultimate (Free) Tool to Sync Clips: https://blog.frame.io/2017/05/15/sync-clips-in-davinci-resolve/
- [RESOLVE-GUIDES] (snippet) https://www.miracamp.com/learn/davinci-resolve/sync-audio-and-video and https://2pop.calarts.edu/technicalsupport/sync-in-davinci-resolve/
- [MAXON-PE] Maxon Red Giant help, PluralEyes troubleshoot the sync: https://help.maxon.net/rg/en-us/Content/html/Pluraleyes-troubleshoot-the-sync.html
- [PE-LAUNCH] (snippet) https://www.provideocoalition.com/new-pluraleyes-3-5-released-as-part-of-shooter-suite-12-5-update/
- [PREMIERE-SYNC] (snippet, HTTP 403) https://helpx.adobe.com/premiere/desktop/add-audio-effects/basic-audio-editing/synchronize-clips-in-the-timeline-panel.html
- [PREMIERE-MC] (snippet, HTTP 403) https://helpx.adobe.com/premiere/desktop/edit-projects/set-up-multi-camera-sequences-for-editing/create-a-multi-camera-source-sequence.html
- [HB-GUIDES] Hindenburg Academy guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [AUDACITY-ALIGN] Audacity manual, Audio Alignment: https://manual.audacityteam.org/man/audio_alignment.html
- [AUPHONIC-TIPS] Auphonic, Multitrack Best Practice: https://auphonic.com/help/algorithms/multitrack_tips.html
- [AUPHONIC-MT] Auphonic, multitrack algorithms: https://auphonic.com/help/algorithms/multitrack.html
- [AUPHONIC-API] (snippet) https://auphonic.com/help/api/multitrack.html
- [DOUBLEENDER] The Incomparable, Double Ender: https://theincomparable.com/doubleender/
- [RIVERSIDE] (snippet, HTTP 403) https://support.riverside.com/hc/en-us/articles/24552483204637
- [VOCALIGN] (snippet) https://kmraudio.com/products/synchro-arts-vocalign-project
- [SOS-CUBASE] (snippet) https://www.soundonsound.com/techniques/cubase-pro-audio-alignment-adr
- [RAFFEL] C. Raffel and D. P. W. Ellis, Estimating timing and channel distortion across related signals, ICASSP 2014 (text extracted from the PDF): https://www.ee.columbia.edu/~dpwe/pubs/RaffelE14-remix.pdf
- [DXCP-ARXIV] Double-cross-correlation processor for sampling-rate-offset estimation: https://arxiv.org/abs/2105.13743 (read at https://ar5iv.labs.arxiv.org/html/2105.13743)
- [EUSIPCO21] (snippet) Yamaoka, Ono, Wakabayashi, https://eurasip.org/Proceedings/Eusipco/Eusipco2021/pdfs/0001125.pdf
- [MATHWORKS-GCC] MathWorks, gccphat: https://www.mathworks.com/help/phased/ref/gccphat.html
- [WEB-GCC] (snippet) https://www.dsprelated.com/showthread/comp.dsp/110350-2.php and https://www.mdpi.com/2079-9292/12/20/4196
- [BBC-AOF] BBC audio-offset-finder README: https://github.com/bbc/audio-offset-finder
- [KAMMERL] Kammerl et al., Temporal Synchronization of Multiple Audio Signals, ICASSP 2014: https://research.google/pubs/temporal-synchronization-of-multiple-audio-signals/
- [DBLP-SHRESTHA] (citation only) https://dblp.org/pid/17/22 and https://dl.acm.org/doi/10.1145/1178782.1178785
- [PSR-SNIPPET] (snippet) https://arxiv.org/pdf/2502.16569 and https://mlanthology.org/cvpr/2010/bolme2010cvpr-visual
- [FORASOFT] Fora Soft, drift correction by resampling: https://www.forasoft.com/learn/audio-for-video/articles-audio/drift-correction-resampling-frame-drop
- [ADI-AC97] (snippet) https://www-cce.cldnet.analog.com/media/en/technical-documentation/application-notes/8046700ee_59.pdf
- [APPLE-AGG] (snippet) Apple, Audio MIDI Setup aggregate device settings: https://support.apple.com/guide/audio-midi-setup/ams094c7edb4/mac
- [NETEQ] WebRTC NetEq: https://chromium.googlesource.com/external/webrtc/+/master/modules/audio_coding/neteq/g3doc/index.md
- [SKLEARN] scikit-learn, Robustness regression: https://scikit-learn.org/stable/modules/linear_model.html
- [FFTW] FFTW benchmark method: https://www.fftw.org/speed/method.html
- [VDSP-H] Local SDK header: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks/vecLib.framework/Versions/A/Headers/vDSP.h`
- [SWIFTINTERFACE] Local SDK: `.../MacOSX.sdk/usr/lib/swift/Accelerate.swiftmodule/x86_64-apple-macos.swiftinterface`
- [AUDIOCONVERTER-H] Local SDK: `.../MacOSX.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AudioConverter.h`
- [VFORCE-H] Local SDK: `.../vecLib.framework/Versions/A/Headers/vForce.h`
- [AVAUDIOFORMAT-H], [VARISPEED-H] Local SDK: `.../AVFAudio.framework/Headers/AVAudioFormat.h` and `AVAudioUnitVarispeed.h`
