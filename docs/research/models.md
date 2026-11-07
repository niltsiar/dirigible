# Research: Whisper models for Spanish with English tech terms, and grading without a reference

Date: 2026-11-07

Run: `2026-11-03-whisper-model-trial`. The sections Q1 to Q4 are research of 2026-11-03. The section **Trial results** holds the measured data of 2026-11-07. Basis: `docs/research/whisper.md` (Date 2026-10-28), cited as F18, F21, F30, F31 and not repeated. New findings start at R1 because the earlier file uses F-numbers.

Marks: "Fact" means a primary source says it (the source is named). "Inference:" means the author derived it. No probe, build, download, or transcription ran for the sections Q1 to Q4. All Hugging Face data was read with the API (`https://huggingface.co/api/models/<repo>`) on 2026-11-03. Download counts are the 30-day counts of the API.

## Corrections to the brief

1. Fact: upstream whisper.cpp v1.9.5 can run NVIDIA Parakeet TDT. It has `src/parakeet.cpp`, `include/parakeet.h`, `examples/parakeet-cli`, and `models/convert-parakeet-to-ggml.py` (tree of tag `v1.9.5`). The `whisper_full` API cannot load it. The vendored target `Sources/CWhisper` does not hold `parakeet.cpp` (`rg -il parakeet Sources/CWhisper` finds nothing). See R12.
2. Fact: `whisper_full_default_params` sets `no_context = true`, but `no_context` only clears the text history at the start of each `whisper_full` call. See R15. The sentence at `docs/research/whisper.md` line 275 ("the default `no_context = true` already drops the previous text") is true only between calls, not between windows of one call.
3. Fact: the HF card of `openai/whisper-large-v3` says `license: apache-2.0`. The card of `openai/whisper-large-v3-turbo` says `license: mit`. F18 reports MIT for the `ggerganov/whisper.cpp` card, for the `openai/whisper` repo, and for turbo, and does not address the large-v3 card. Confirm the license text for large-v3 before a catalog entry.

## Q1. Whisper-architecture candidates

### R1. What whisper.cpp v1.9.5 can load

- Fact: `whisper_model_load` (`Sources/CWhisper/src/whisper.cpp` lines 1519 to 1538) checks the magic `GGML_FILE_MAGIC` (the bytes of `ggml`). It then reads 11 integers: `n_vocab`, `n_audio_ctx`, `n_audio_state`, `n_audio_head`, `n_audio_layer`, `n_text_ctx`, `n_text_state`, `n_text_head`, `n_text_layer`, `n_mels`, `ftype`. The mel filters and the vocabulary come from the file.
- Fact: a GGUF file has another magic. whisper.cpp v1.9.5 cannot load it. This excludes `handy-computer/*-gguf` (library `transcribe.cpp`) and `xkeyC/whisper-large-v3-turbo-gguf`.
- Fact: `n_mels` comes from the header (80 or 128), so large-v3 and turbo (128 bins) load. The decoder depth also comes from the header, so turbo (4 decoder layers) and 2-layer distilled models load.
- Fact: the special-token ids come from `n_vocab` alone (lines 453 to 470, 1645 to 1658): `is_multilingual()` is `n_vocab >= 51865`, and `num_languages()` is `n_vocab - 51765 - 1`. A model with a changed vocabulary layout (other count of special tokens, other order) breaks the language and timestamp tokens. Models that keep the 51866 layout of large-v3 load.
- Fact: line 7213 treats `n_text_layer == 2 && n_vocab != 51866` as a first-release distilled model and forces `no_timestamps`. A 2-layer model with 51866 tokens does not take this path.
- Fact: a model that is not a GGML file needs a conversion. `models/convert-h5-to-ggml.py` (tag `v1.9.5`) reads `config.json` and `vocab.json` of the model folder, loads the weights with `transformers` and `torch`, and needs a checkout of `openai/whisper` for `whisper/assets/mel_filters.npz`. It writes `ggml-model.bin` in f16 only (or f32 with a fourth argument). Quantization to q5_0 is a second step with the `quantize` tool of whisper.cpp, which needs a CMake build. The folder `models/` is not vendored in `Sources/CWhisper`.
- Fact: the three repos checked (`marianbasti/whisper-large-v3-turbo-latam`, `adriszmar/whisper-large-v3-turbo-es`, `HiTZ/whisper-large-v3-es`) have `vocab.json` and `merges.txt` (API `siblings`). The repos of BSC-LT, `marianbasti/distil-whisper-large-v3-es`, `UNRN/distil-whisper-large-v3-es`, and `projecte-aina/whisper-large-v3-tiny-caesar` were not checked. The BSC-LT file list shows no `tokenizer.json`. The converter reads `vocab.json` at a fixed path, so a repo without it fails conversion.
- Fact: `efficient-speech/lite-whisper-large-v3-turbo-acc` has `architectures: LiteWhisperForConditionalGeneration` and a `low_rank_config` per layer. Inference: the low-rank layers have other tensor shapes than the full matrices that the loader creates, so the file does not load. Not tested.

### R2. OpenAI sizes and quantizations in `ggerganov/whisper.cpp`

Fact: revision `5359861c739e955e79d9a303bcbc70fb988958b1` (last modified 2024-10-29) is still the head on 2026-11-03. The card says `license: mit`. Bytes and SHA-256 (LFS oid) from the API:

| File | Bytes | SHA-256 |
|---|---|---|
| `ggml-small.bin` | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| `ggml-small-q8_0.bin` | 264,464,607 | `49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f` |
| `ggml-medium.bin` | 1,533,763,059 | `6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208` |
| `ggml-medium-q5_0.bin` | 539,212,467 | `19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f` |
| `ggml-medium-q8_0.bin` | 823,369,779 | `42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502` |
| `ggml-large-v2-q5_0.bin` | 1,080,732,091 | `3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2` |
| `ggml-large-v3-q5_0.bin` | 1,081,140,203 | `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1` |
| `ggml-large-v3-turbo-q8_0.bin` | 874,188,075 | `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1` |

Sizes of the other files: F18. `ggml-large-v2-q8_0.bin` is 1,656,129,691 bytes. `ggml-large-v2.bin` is 3,094,623,691 bytes.

Spanish WER. Two sources, and they use different methods:

- Fact (F30, Whisper paper, original OpenAI models, Fleurs Spanish): small 5.6, medium 3.6, large 3.5, large-v2 3.0. Common Voice 9 Spanish: small 10.3, medium 6.9, large-v2 5.6. Turbo has no paper number (F31).
- Fact (third-party): the cards of `handy-computer/whisper-<size>-gguf` list a Fleurs Spanish WER for the q8_0 file, measured with the runtime `transcribe.cpp`: tiny 18.95, base 11.15, small 5.92, medium 3.8, large-v2 3.3, large-v3 2.7, large-v3-turbo 3.12. The card of turbo gives no split, normalizer, decoding, or hardware for the Fleurs figures (the page `docs/models/whisper-large-v3-turbo.md` of `transcribe.cpp` does not either). It gives, for LibriSpeech test-clean (English): F16 2.01, Q8_0 2.01, Q6_K 2.01, Q5_K_M 2.03, Q4_K_M 2.04.
- Inference: the order is large-v3 < large-v2 < turbo < medium < small for Spanish read speech. The gap between large-v3 and turbo is 0.4 points on Fleurs. Fleurs is clean read speech, so it says little about a call-app voice.
- Inference: a q5_0 or q5_1 file of ggerganov loses a little accuracy against f16. The only quantization numbers found are English (above). The size of the loss for Spanish is unknown (same open point as P11 of `docs/research/whisper.md`).
- Fact (`docs/research/whisper.md` line 275, issue 1507 of whisper.cpp): the maintainer saw repeat loops that come from the large-v3 model. Inference: large-v2 is a hedge against repeats. No source compares the hallucination rate of large-v2 and large-v3 on Spanish.
- Inference: encoder cost grows with the parameter count (small 244 M, medium 769 M, large 1550 M, turbo 809 M, from the OpenAI model card table). F21 gives an encoder-only RTF of 0.14 to 0.76 for small on 4 Intel cores. Medium is about 3 times small (0.45 to 2.4) and large about 6 times small (0.9 to 4.9, F21 gives at least 1.2). For 67 min of audio, the encoder alone takes about 30 min to 160 min for medium and 80 min or more for any large-class file (turbo included, because its encoder is the large-v3 encoder). Not measured.

### R3. Spanish fine-tunes of Whisper

Fact: among the repos found, no Spanish fine-tune has more than 3,200 downloads in 30 days (several API searches by download count on 2026-11-03; the search is not exhaustive). The most downloaded is `marianbasti/whisper-large-v3-turbo-latam` (3,148). The others have under 300. The most downloaded Whisper-architecture models with Spanish in their language list are the OpenAI models themselves.

| Repo | Revision | License | Base | Format | Spanish WER on its card | GGML in v1.9.5? |
|---|---|---|---|---|---|---|
| `marianbasti/whisper-large-v3-turbo-latam` | `e22f0ff16b5ec1bfb79b225e1fd3c108d1e15dde` | mit | large-v3-turbo | safetensors, 3,235,581,408 bytes | Common Voice 17 es, 3,952 samples: 15.44 (base turbo) to 7.80 (fine-tune), own eval | After conversion (R1). A third party already converted it: `JoaoZaokk/whisper-large-v3-turbo-latam-ggml` (revision `68d00d9ce2abbf86e16dcdbc0d387db751b91651`, mit, f16 1,624,555,275 bytes, q4_0 473,992,235, q5_0 574,041,195, q8_0 874,188,075). Its card says each file was tested with Portuguese and English samples, not Spanish. |
| `adriszmar/whisper-large-v3-turbo-es` | `b32b7042f31dbf695857e3a81037a43b97f1eee1` | mit | large-v3-turbo | safetensors, 3,235,581,408 bytes | Common Voice 17 es test: 6.91 (base) to 5.34 (fine-tune), own eval | After conversion. Third-party GGML: `Sendery/whisper-large-v3-turbo-es-ggml` (revision `5c2ba1a89259ddcd94c9d029938e08a7b04e84b3`, mit, one f16 file `ggml-model.bin`, 1,624,555,275 bytes). |
| `HiTZ/whisper-large-v3-es` | `e26ad7fbe88fd92db14f093394d2c51815123a87` | apache-2.0 | large-v3 | safetensors, 2 shards, 6.17 GB | Common Voice 13 es test: 4.93 (no base figure) | After conversion; f16 3.1 GB. `zuazo/whisper-large-v3-es` has the same safetensors SHA-256 values (`17b58f02c0bb...`, `0acee9578e8f...`), so it is the same weights in a second repo. |
| `marianbasti/distil-whisper-large-v3-es` | `f582a954bfbb8e1fb7989abde0755117aec06945` | mit | distilled from large-v3, Common Voice 16.1 | safetensors, 3,025,686,432 bytes (f32) | None on the card | After conversion. `config.json`: 32 encoder layers, 2 decoder layers, 51866 vocabulary, 128 mels. It takes the load path of large-v3 (R1). `UNRN/distil-whisper-large-v3-es` (revision `21d6ee2bb74bedc54485068c889f63c1f371bae1`) has the same config and no WER on the card. |
| `BSC-LT/whisper-large-v3-LoS-punctuated` | `8f2236c6fd7d66ad3d476fd00b2d55789ccaa9e5` | apache-2.0 | large-v3 | `.bin` (PyTorch) shards, 6.17 GB | The card has an empty WER field (Catalan test) | After conversion; Spanish, Catalan, Galician, Basque; 8,110 h of training data. |
| `projecte-aina/whisper-large-v3-tiny-caesar` | `cf087e16e4403d80bf944d3761dd9ba5dc1ed0bc` | apache-2.0 | large-v3 | safetensors, 6.17 GB | Not read | After conversion. Not examined further. |

- Fact: the older Spanish fine-tunes (`deepdml/whisper-medium-mix-es`, 2022, apache-2.0, Fleurs es_419 4.03, Common Voice 11 es 6.35, MLS 4.66, VoxPopuli 8.37; `clu-ling/whisper-large-v2-spanish`; `zuazo/whisper-*-es`) have under 100 downloads each.
- Fact: the two baselines for plain turbo on Common Voice 17 es differ: 15.44 (card of `marianbasti`, 3,952 samples, the "evaluation split") and 6.91 (card of `adriszmar`, "test split"). The cards name different splits and state no normalization. Do not compare 7.80 with 5.34.
- Fact: `marianbasti/whisper-large-v3-turbo-latam` was trained on Common Voice 17 es "filtering out accents from Spain" (its card). Inference: the tester's podcast accent is not known to the author of this file. If it is from Spain, this model is a mismatch by design.
- Inference: every Spanish fine-tune above trains on Common Voice (read speech, no English tech terms). A lower Common Voice WER says nothing about "TanStack Start" or "Next.js". Fine-tuning only on Spanish text can also lower the recognition of English terms in the middle of Spanish speech (forgetting). No source measured this for these models. The term-list score of R10 tests it.
- Inference: a fine-tune of turbo has the speed of turbo (large-v3 encoder, F21), so it is as slow as large-v3 on the Intel Mac. A distilled model with 2 decoder layers saves decoder time only, and F21 says the encoder dominates on this Mac.

### R4. Distilled models

- Fact: `distil-whisper/distil-large-v3` (card: "third and final installment of the Distil-Whisper English series", `language: en`), `distil-whisper/distil-large-v3.5` (revision `728a7691f3ff1d3d971528d3203a6e9559165d41`, `language: en`), `distil-whisper/distil-large-v2`, `distil-medium.en`, and `distil-small.en` are English only. Their GGML repos (`distil-whisper/distil-large-v3-ggml`, `distil-whisper/distil-large-v3.5-ggml`) are English too. The card of `distil-large-v2` says "Distil-Whisper is currently only available for English speech recognition."
- Fact: the multilingual distilled models found for Spanish are the two in R3 (`marianbasti/...`, `UNRN/...`), with no published WER. Other multilingual distils on the search (`freds0` for Portuguese, `biodatlab` for Thai, `bofenghuang` for French and Italian) are not Spanish.

## Q2. Non-Whisper models with Spanish

### R12. Parakeet and Canary

- Fact: `nvidia/parakeet-tdt-0.6b-v3` (revision `541d1f99c6b0c3cd0b11a95167540bb8edefd82b`, `cc-by-4.0`, 25 languages including `es`, 574,141 downloads in 30 days). WER from the model index of its card: Fleurs es_419 3.45; Multilingual LibriSpeech Spanish 4.39; CoVoST2 es 3.41. Runtime: NVIDIA NeMo (PyTorch), or ONNX (`istupakov/parakeet-tdt-0.6b-v3-onnx`), CoreML (`FluidInference/parakeet-tdt-0.6b-v3-coreml`), MLX (`mlx-community/parakeet-tdt-0.6b-v3`), or whisper.cpp v1.9.5 through the separate Parakeet API.
- Fact: upstream whisper.cpp v1.9.5 has `parakeet-cli`. Its README: build with `cmake --build build --target parakeet-cli`, then `parakeet-cli -m models/ggml-parakeet-tdt-0.6b-v3-f16.bin -f file.wav`. The models are in `ggml-org/parakeet-GGUF` (revision `35156454d1a39de06863303dd209fd2bed6ee079`, `license: mit` on the repo card, base `nvidia/parakeet-tdt-0.6b-v3`): f32 2,508,463,079 bytes, f16 1,255,897,319, q8_0 668,757,119, q4_0 355,615,679, q4_k 415,611,879. The file names end in `.bin`, but the repo says GGUF. The file format is the one of `parakeet.cpp`, not the one of `whisper_full`.
- Fact: the app cannot load it today. `whisper_model_load` is the only loader in `Sources/CWhisper`, and `parakeet.cpp` is not in the target (`README.dirigible` lists the files). Inference: using Parakeet in the app needs vendoring `src/parakeet.cpp`, `src/parakeet-arch.h`, and `include/parakeet.h`, a second engine API, and the license text of NVIDIA (CC-BY-4.0 needs attribution). Speed on the Intel Mac is not known.
- Fact: `nvidia/canary-1b-v2` (revision `d455706339a6b32e1aa40f82c713a482a0c938e2`, `cc-by-4.0`, 25 European languages). WER from its card: Fleurs es_419 2.9; Multilingual LibriSpeech Spanish 2.94; CoVoST2 es 3.81. Runtime: NeMo. No whisper.cpp path was found in the tree of v1.9.5. A third-party GGUF runtime for Parakeet-family models exists (`mudler/parakeet-cpp-gguf`); the author did not check whether it includes Canary.
- Inference: both models write text without an initial-prompt feature. The Whisper-style prompt of R16 does not apply.
- Fact: these are the best two found. They match or beat large-v3-turbo on read-speech Fleurs Spanish (3.12 third-party, R2). The comparison mixes sources and methods.

## Q3. Grading without a human reference

### R6. Multi-system consensus (ROVER) as pseudo-reference

- Fact (Fiscus 1997, text of the NIST paper in SCTK `rover.htm`): ROVER aligns the outputs of several systems into one word transition network and votes at each position. On the 1997 Hub-5E data, five systems had 44.9, 45.1, 48.7, 48.9, and 50.2 percent WER. ROVER with three voting schemes gave 39.7, 39.5, and 39.4. Fact: the paper does not say the systems must be independent, does not study the number of systems, and says the result depends on the merge order. It also says the parameters came from 1996 data and may not generalize.
- Fact (arXiv 1706.07238, "Automatic Quality Estimation for ASR System Combination", abstract): ROVER output improves when the hypotheses are ranked by quality estimation; absolute WER gains over plain ROVER were 0.5 to 7.3 percent in two tasks. This is system combination, not evaluation.
- Fact (ACL Findings 2025, "On the Robust Approximation of ASR Metrics", abstract): a label-free WER estimate uses agreement with a high-quality proxy model plus a regression model. It stays within a single-digit absolute difference of the true metric on over 40 models and 14 datasets. The author could not read the full text (PDF was not machine-readable), so the rank correlation and any bias analysis are not confirmed.
- Not found: a primary source that ranks several ASR systems by ROVER agreement and reports the rank correlation with true WER. Not found: a measurement of the bias of a consensus reference toward the systems in the vote.
- Inference: a consensus reference scores the systems that vote highest, because shared errors count as agreement. The candidates here share the large-v3 encoder or its fine-tunes, so their common errors (for example the same wrong spelling of "TanStack") become the reference. Leave-one-out (a system is scored against the vote of the others) removes self-voting but not shared errors. Use consensus only as a secondary signal.

### R7. LLM judge that reads transcripts without the audio

- Fact (arXiv 2608.25574, 2026, French, HATS dataset): a generative LLM given a reference and two hypotheses picked the hypothesis that humans preferred with 94 percent agreement (GPT-4.1), 92 (Qwen3.5-35B), 87 (Gemma4-31B), 72 (Gemma3-27B), 50 (Qwen3-0.6B), on the subset where all human judges agree. On all pairs: 79, 78, 73, 61, 47. WER on the same subset: 63 percent agreement. CER: 77. The prompt had a reference text. So this does not test a judge that has no reference.
- Fact (search of arXiv and web, 2026-11-03): no source tests a prompted LLM that sees only competing transcripts (no reference, no audio) against system WER ranking.
- Fact (arXiv 2306.12577, NoRefER, Interspeech 2023): a fine-tuned (not prompted) referenceless model correlates with sample-level WER ranks at Pearson 0.42 to 0.58 and with WER scores at 0.30 to 0.49 (Common Voice English, French, Spanish and LibriSpeech English; six commercial engines including Whisper-large). Spanish: ranking 0.58 / 0.52 / 0.58 (Pearson / Spearman / Kendall), score 0.49 / 0.40 / 0.30. These are per-sample correlations, not system-level ranking.
- Inference: a text-only judge sees fluent text only. Whisper errors on tech terms and some hallucinations are fluent, so the judge cannot see them without the audio. A judge can compare spellings of known terms and flag nonsense words. It cannot rank systems by true accuracy. The risk of position bias and self-preference in LLM judges is known in general but this file did not read a source for it.

### R8. Keyword or term-list accuracy

- Fact: the contextual-biasing literature scores a word list apart from the rest: B-WER (biased words, those in the list) and U-WER (words not in the list). arXiv 2406.16120 names both and cites Le et al., Interspeech 2021, for the definition. The author did not read that paper. The exact definition here is from search summaries only.
- Secondary, not read: search summaries say the Conformer-1 report (arXiv 2404.07341) says WER alone does not capture fine-grained entities such as proper nouns and scores them apart. The same summaries say that rare words are a small share of a transcript, so their errors move overall WER little.
- Not found: a source that gives the rank correlation between a term-list score and WER at system level.
- Inference: with 12 terms and several mentions each, the term score has a wide interval. Report counts (found of total), not a percentage alone. It measures exactly what the tester complained about. It does not measure the rest of the speech.

### R9. What the sources say, in one line each

- Fact: no primary source found gives a system-level ranking agreement with true WER for any of the three methods without a human reference.
- Fact: every method in R7 and R8 that a source validates was validated against a human or a reference transcript.
- Inference: a short human reference is the only way to know how well any of the three methods ranks these systems. A 5-minute slice that a person corrects costs little against a 67-minute trial. It is outside the "no human reference" constraint of the brief. It gives a way to check the other methods.

### R10. Recommended grading method (Inference)

1. Primary: term accuracy on the 12 terms. Count, per system, the mentions that appear with the correct spelling (case-insensitive, space and hyphen rules fixed before the run). The tester lists the mentions by time stamp, or listens once. Report found/total per term and a total.
2. Secondary: a consensus score by leave-one-out. For each system, align it to the vote of all other systems, and report the word disagreement. State in the report that the candidates share an encoder, so a low disagreement can mean shared errors. Drop a system from the vote when it is a fine-tune of another system in the vote.
3. Checks that need no reference: the count of repeated n-gram loops (same 4-gram 5 or more times in a row), the count of words per minute against the other systems, the count of windows with no text during speech. These find hallucination and dropped speech.
4. LLM judge: use it for one job only, to list the spellings each system gave for each of the 12 terms and for the other English words, so a person reads one table. Do not use it to rank.
5. Calibration (outside the stated constraint): one person corrects a 5-minute slice that has both voices and at least 6 of the 12 terms. Compute true WER on the slice for each system. Check that the term score and the consensus score give the same order. Without this step, the order from methods 1 to 4 has no measured link to WER.

## Q4. `initial_prompt`

### R14. What whisper.cpp does (source of the vendored v1.9.5)

- Fact (`Sources/CWhisper/include/whisper.h` lines 521 to 528): `initial_prompt` gives "tokens to provide to the whisper decoder as initial prompt", "prepended to any existing text context from a previous call", "maximum of whisper_n_text_ctx()/2 tokens are used (typically 224)". `carry_initial_prompt`: "if true, always prepend initial_prompt to every decode window (may reduce conditioning on previous text)". The CLI flags are `--prompt` and `--carry-initial-prompt` (`examples/cli/cli.cpp`, tag `v1.9.5`).
- Fact (`whisper.cpp` lines 7150, 7157 to 7185): the budget is `min(n_max_text_ctx, n_text_ctx / 2)`, so 224 tokens for the standard models. The text is tokenized with `whisper_tokenize`.
- Fact: with `carry_initial_prompt = false` (the default), the prompt tokens go into the rolling history `prompt_past1` (lines 7183 to 7185). After each window, the history is the old prompt tokens plus the tokens just decoded (lines 7834 to 7845). Each window takes at most 223 of the last history tokens (lines 7350 to 7351). Inference: the hint leaves the window after about 223 tokens of new text, which is about 1 to 3 windows of speech. Not measured.
- Fact: with `carry_initial_prompt = true`, the prompt sits in `prompt_past0` and goes at the front of every window (lines 7335 to 7351). The rolling history gets the remaining budget. A prompt longer than the budget keeps its last tokens and logs a warning (line 7176).
- Fact (line 7334, constant at line 152): the history is used only when the decode temperature is below 0.5 (`WHISPER_HISTORY_CONDITIONING_TEMP_CUTOFF`). A window that fell back to a higher temperature has no prompt.
- Fact (lines 7266 to 7271): when the last audio segment is short, `whisper_full` removes the past prompt "since it tends to confuse the decoder and often make it repeat or hallucinate stuff".
- Fact: the app today uses `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)` and sets no prompt (`Sources/DirigibleAudio/Transcribe/WhisperEngine.swift` lines 105 to 116). So `initial_prompt = nullptr`, `no_context = true`, `n_max_text_ctx = 16384`, `carry_initial_prompt = false`.

### R15. `no_context` and the history inside one call

- Fact: `no_context` has one use in `whisper_full_with_state` (lines 7144 to 7147). It clears `prompt_past0` and `prompt_past1` once, at the start of the call. Nothing clears them between windows, except the temperature rule, the short-last-segment rule, and `n_max_text_ctx = 0`.
- Inference: the app, with its defaults, already feeds the text of the previous window (up to 223 tokens) into the next window inside one piece. A wrong spelling in one window can repeat in the next. This differs from the sentence at `docs/research/whisper.md` line 275. Open question: confirm with a debug log of the prompt (the `WHISPER_LOG_DEBUG` at the "print the prompt" block).

### R16. What OpenAI says

- Fact (OpenAI cookbook, Whisper prompting guide): the prompt is for joining segments (the previous transcript as context). It can set the spelling of names, products, companies, and acronyms, and the writing style. "Only the final 224 tokens of the prompt will be considered." The techniques "are not especially reliable, but can be useful in some situations". A prompt "will not override the model's comprehension of the audio". Prompts are not instructions. The guide does not discuss hallucination.
- Fact (OpenAI speech-to-text guide): "Whisper doesn't follow instructions like a general-purpose text model and accepts prompts of up to 224 tokens". The prompt can pass "a dictionary of the correct spellings", and a list of terms is limited to 224 tokens.
- Fact (`openai/whisper` `transcribe.py`): `initial_prompt` is "text to provide as a prompt for the first window ... custom vocabularies or proper nouns". The prompt is encoded with a leading space (`" " + initial_prompt.strip()`). `condition_on_previous_text` is documented as: disabling it makes the model "less prone to getting stuck in a failure loop". The same file stops the history when the temperature is above 0.5.
- Fact: a research paper (arXiv 2502.11572) calls prompting the existing way of contextual biasing for Whisper and says Whisper "faces difficulty in recognising rare words like domain-specific terms". It fine-tunes the model for English prompts and reports a 45.6 percent gain on rare words for that fine-tune. The abstract says the biasing ability carries over to unseen languages. The author read the abstract only.
- Not found: a measurement of an English term list in the prompt for Spanish speech with a stock Whisper model.
- Inference: a Spanish sentence that contains the 12 terms in their correct spelling ("Hablamos de TanStack Start, Next.js, ...") is the form that follows the tokenizer and the language of the audio. A bare English list can push the decoder to English output. Hallucination risk is higher with a long prompt, with `carry_initial_prompt`, and at the end of the audio. The trial can test: no prompt, a prompt, and a prompt with carry, on one model, scored with R10 step 1 and the repeat-loop check.

## Claims that no source confirmed

- Spanish WER of the quantized ggerganov files (R2). The only quantization numbers are English (LibriSpeech, third-party GGUF).
- The method behind the `handy-computer` Fleurs Spanish figures (split, normalizer, decoding).
- Speed of medium, large-v3, and large-v3-q5_0 on the dev Intel Mac (R2 is derived from F21).
- That `JoaoZaokk/whisper-large-v3-turbo-latam-ggml` and `Sendery/whisper-large-v3-turbo-es-ggml` give correct Spanish text (the cards do not show a Spanish test).
- Any Spanish WER for the two distilled Spanish models and for `BSC-LT/whisper-large-v3-LoS-punctuated`.
- That Spanish fine-tunes keep or lose English tech terms (R3, Inference).
- The rank correlation of ROVER or consensus agreement with true WER, and its bias toward the voters (R6).
- The rank correlation of a term-list score with true WER (R8). The B-WER and U-WER definitions are not from a primary source that the author read.
- An LLM judge with no reference and no audio (R7).
- The effect of an English term list in the prompt for Spanish speech (R16).
- That a lite-whisper file fails to load (R1).
- The accent of the tester's podcast (needed to judge the "latam" model).
- The license that applies to `ggml-large-v3-q5_0.bin`. The card of `ggerganov/whisper.cpp` says MIT and F18 cites it. The Transformers card of `openai/whisper-large-v3` says apache-2.0. Inference: the ggml file derives from the OpenAI checkpoint of the MIT `openai/whisper` repo, so the ggerganov statement applies. The two OpenAI publications disagree.

## Open questions (probes that need a build, a download, or a run)

- Q-A and Q-C are answered by the trial: see **Setup** and **Speed and memory** in `## Trial results`.
- Q-B. Convert `marianbasti/whisper-large-v3-turbo-latam` (or use the JoaoZaokk files) and check Spanish output on 1 minute of the tester audio before the full run.
- Q-D. Dump the decoder prompt of window 2 with the app defaults (R15) and with `initial_prompt` set (R14).
- Q-E. Build `parakeet-cli` from tag `v1.9.5` and run `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` (668,757,119 bytes) on the slice. Needs a CMake build and a download over 10 MB.
- Q-G. Check that `vocab.json` exists in the BSC-LT, distil-es, and caesar repos before any conversion.
- Q-F. Ask the tester for the 12 terms with their expected spelling and the time stamps of 2 or 3 mentions each, and for one 5-minute corrected slice (R10 step 5).

## Candidate table (expectation before the trial)

This table is the expectation before the trial. `## Trial results` replaces its ranking. Rank is the expected value for the trial question (Spanish with English tech terms, Intel CPU), not a measured result. "Fact" and "Inference:" apply to the Spanish WER and loadability columns only. Revision for all ggerganov rows: `5359861c739e955e79d9a303bcbc70fb988958b1`.

| Rank | Model (file) | Size (bytes) | Spanish WER, test set | Loads in v1.9.5 | Why in the trial |
|---|---|---|---|---|---|
| 1 | `ggerganov/whisper.cpp` `ggml-large-v3-q5_0.bin` | 1,081,140,203 | 2.7 Fleurs (q8_0, third-party, method unknown): Fact. Quantized-file loss for Spanish: unknown | Fact: yes (v3 path, line 1564) | Strongest published Spanish accuracy of the OpenAI family. Slow on Intel (Inference: RTF >= 1.2 for the encoder alone). Repeat-loop risk (line 275 of `docs/research/whisper.md`). |
| 2 | `ggml-large-v3-turbo-q8_0.bin` | 874,188,075 | 3.12 Fleurs (q8_0, third-party): Fact | Fact: yes (the catalog loads turbo-q5_0) | Closer to f16 than the catalog q5_0. Same encoder cost as rank 1: Inference. Tests the effect of quantization in the catalog. |
| 3 | `ggml-medium-q5_0.bin` | 539,212,467 | 3.6 Fleurs, 6.9 Common Voice 9 (paper, f16 original): Fact | Fact: yes | Likely the best fit for the Intel Mac: Inference (about 3 times small, R2). Small gap to turbo on Fleurs. |
| 4 | `ggml-large-v2-q5_0.bin` | 1,080,732,091 | 3.0 Fleurs, 5.6 Common Voice 9 (paper, f16): Fact | Fact: yes | Hedge against v3 repeat loops: Inference. Same cost as rank 1. |
| 5 | `JoaoZaokk/whisper-large-v3-turbo-latam-ggml` `...-q5_0.bin` (revision in R3) | 574,041,195 | 7.80 vs 15.44 base on Common Voice 17 es (own eval, odd baseline): Fact | Fact: card says whisper.cpp; Spanish output not tested by the author of the repo | The most downloaded Spanish fine-tune. Tests "Spanish fine-tune vs English terms": Inference. Latin American accent bias. |
| 6 | `Sendery/whisper-large-v3-turbo-es-ggml` `ggml-model.bin` (revision in R3) | 1,624,555,275 | 5.34 vs 6.91 base on Common Voice 17 es test (own eval) | Fact: card says whisper.cpp; f16 only | Second turbo fine-tune, from a different training run. f16 is 3 times the catalog size. |
| 7 | `HiTZ/whisper-large-v3-es` (needs conversion, revision in R3) | 6,174,112,072 (safetensors) | 4.93 Common Voice 13 es test | Inference: yes after `convert-h5-to-ggml.py` (R1); not tried | Only large-v3 Spanish fine-tune with a published WER. Needs torch, the converter, and a quantize build. |
| 8 | `ggml-small-q8_0.bin` | 264,464,607 | 5.92 Fleurs (q8_0, third-party), 5.6 (paper f16): Fact | Fact: yes | Control for the catalog `small-q5_1`: tests the quantization step on Spanish with the same size class. |
| 9 | `ggml-small.bin` (f16) | 487,601,967 | 5.6 Fleurs, 10.3 Common Voice 9 (paper): Fact | Fact: yes | f16 reference for rank 8 and the catalog `small-q5_1`. |
| 10 | `marianbasti/distil-whisper-large-v3-es` (needs conversion, revision in R3) | 3,025,686,432 (safetensors, f32) | No WER published | Inference: yes after conversion (R1, R3) | Only multilingual distil for Spanish. Saves decoder time only, so little gain on this Mac: Inference. Low rank. |
| 11 | Parakeet TDT 0.6B v3, `ggml-org/parakeet-GGUF` `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | 668,757,119 | 3.45 Fleurs es_419, 4.39 MLS, 3.41 CoVoST2 es (NVIDIA card): Fact | Fact: no with `whisper_full`; the `parakeet.cpp` API of v1.9.5 runs it, not vendored | Reference only. It shows what a non-Whisper model does on the tech terms. No app change in this trial. |
| 12 | Excluded, not ranked: `distil-large-v3` and `-v3.5` (English only), GGUF repos (`handy-computer`, `xkeyC`), lite-whisper, Canary-1b-v2 (needs NeMo; no whisper.cpp path found) | n/a | n/a | Fact for the first three groups (R1, R4); Inference for lite-whisper | Not run. |

## Grading method

The trial grading method is in **Setup** of `## Trial results`. R10 is the research input to it.

## Trial results

Graded on 2026-11-07, run `2026-11-03-whisper-model-trial`. This section holds measured data. The sections above hold research from sources.

### Setup

- Seven models ran on 9 excerpts of tester audio (16 kHz mono, 14 tracks): base, small-q5_1, medium-q5_0, turbo-q5_0, turbo-q8_0, large-v3-q5_0, and latam-q5_0 (`JoaoZaokk/whisper-large-v3-turbo-latam-ggml`, q5_0). The app transcription path ran each one through `dirigible transcribe --model-file`. Each file matched its pinned SHA-256.
- Set 1 is X1 to X4 (episode 353, 3377 reference words). Set 2 is W1 to W4 (premium episode 360, 2193 reference words). E1 has no reference text, so it gives only loop, misspelling, and LOFO data. Only Spanish audio ran, so the trial gives no evidence for other languages.
- The reference is the tester SRT with the corrections files of its corpus applied. It is not a human transcript. The set 2 SRT comes from WhisperKit `openai_whisper-large-v3-v20240930`, which is large-v3-turbo: its `config.json` has `decoder_layers` 4 (large-v3 has 32) and a `_name_or_path` that ends in `tmp_whisper_turbo`. So the set 2 WER of turbo-q5_0 and turbo-q8_0 is close to self-agreement, and set 2 cannot rank turbo against other models. The model that made the set 1 SRT is not known.
- The machine is an Intel Core i5-8259U (4 cores, 8 threads, 16 GiB), CPU only, no Metal. The speed pass ran S1 (2 tracks of 106.54 s) with the build lock held. The accuracy pass ran at nice 19.
- Grading method (R10 and R6 to R8): the term score decides. A term group is G1 (22 tech names, 19 of them expected in the excerpts), G2 (12 loanwords), or G3 (2 Spanish words that the set 2 corrections fix). A model is better than the baseline turbo-q5_0 only when the exact two-sided binomial on the discordant G1 occurrences gives p below 0.05. LOFO is the mean word error rate against the other voter families (leave one family out). The five models with the large-v3 encoder count as one voter family.
- The grader passed its self-test (25 of 25 asserts) before the final run. The numbers come from one run on the tester corpus. The grader and the corpus are not in this repo, so a reader cannot rerun them from the repo.

### Grades

"p vs baseline" counts the discordant G1 occurrences (model only : turbo-q5_0 only). WER is against the tester text, over all excerpts with a reference. "RTF net" is from the speed pass. "RTF gross" is from the accuracy pass (nice 19, pauses included), so it is not comparable with the net value. MB is 1,000,000 bytes.

| Model | MB | License | G1 found | G2 found | G3 found | Extra hits | Misspellings | p vs baseline | LOFO (families) | WER vs tester | Loops | Dropped bins | WPM flags | RTF net | RTF gross | Peak MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base | 148 | mit | 4/82 | 9/23 | 3/20 | 2 | 15 | 0:24, p 1.2e-07 | 0.207 (4) | 0.276 | 0 | 0/197 | 0 | 0.19 | 1.01 | 539 |
| large-v3-q5_0 | 1081 | mit | 17/82 | 16/23 | 17/20 | 3 | 19 | 5:16, p 0.027 | 0.157 (4) | 0.162 | 1 | 0/197 | 0 | 1.91 | 7.55 | 2415 |
| latam-q5_0 | 574 | mit | 6/82 | 14/23 | 3/20 | 1 | 21 | 2:24, p 1.1e-05 | 0.215 (4) | 0.252 | 0 | 13/197 | 1 | 3.02 | 8.42 | 1281 |
| medium-q5_0 | 539 | mit | 24/82 | 19/23 | 15/20 | 3 | 26 | 6:10, p 0.454 | 0.137 (4) | 0.154 | 0 | 0/197 | 0 | 1.02 | 5.76 | 1456 |
| small-q5_1 | 190 | mit | 22/82 | 12/23 | 14/20 | 4 | 33 | 7:13, p 0.263 | 0.156 (4) | 0.192 | 0 | 0/197 | 0 | 0.52 | 2.29 | 700 |
| turbo-q5_0 | 574 | mit | 28/82 | 16/23 | 17/20 | 5 | 40 | baseline | 0.126 (4) | 0.117 | 0 | 0/197 | 0 | 0.96 | 3.74 | 1208 |
| turbo-q8_0 | 874 | mit | 25/82 | 18/23 | 15/20 | 4 | 41 | 6:9, p 0.607 | 0.127 (4) | 0.113 | 0 | 0/197 | 0 | 0.99 | 6.66 | 1489 |
| app-transcript (external, consensus only) | n/a | unknown | 4/9 | 4/5 | 13/15 | 1 | 1 | 0:1, p 1.000 | 0.085 (4) | 0.055 | 0 | 1/79 | 0 | n/a | n/a | n/a |
| whisperkit-large-v3 (external, consensus only) | n/a | unknown | 9/9 | 5/5 | 15/15 | 0 | 1 | 4:0, p 0.125 | 0.082 (4) | 0.000 | 0 | 0/79 | 0 | n/a | n/a | n/a |

- The two external rows are set 2 only. They vote in LOFO. The WhisperKit row is also the set 2 reference, so its WER is 0 by construction.
- The "app-transcript" row is the Dirigible transcript of the set 2 package. Its model is not known. It drops the 20 to 30 s bin of W4: 8 words against 25 in the reference.
- Expected counts are 82 G1 (19 names), 23 G2, and 20 G3. No model has a found count over its expected count.

### Ranking and T10 picks

The rank follows the T10 rule. First the models that pass the loop, WPM, and dropped-bin checks, by G1 found. Then the excluded models. WER per set is against the tester text. It is an upper limit of the model error. The set 2 WER of turbo-q5_0, turbo-q8_0, and latam-q5_0 (a fine-tune of turbo) is against a large-v3-turbo reference, so it does not rank turbo against other models. Compare set 2 WER only among base, small-q5_1, medium-q5_0, and large-v3-q5_0.

| Rank | Model | G1 | p vs turbo-q5_0 | WER set 1 | WER set 2 | Loops | Dropped bins | WPM flags | Bytes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | turbo-q5_0 | 28/82 | baseline | 0.166 | 0.042 | 0 | 0/197 | 0 | 574,041,195 |
| 2 | turbo-q8_0 | 25/82 | 6:9, 0.607 | 0.160 | 0.042 | 0 | 0/197 | 0 | 874,188,075 |
| 3 | medium-q5_0 | 24/82 | 6:10, 0.454 | 0.225 | 0.044 | 0 | 0/197 | 0 | 539,212,467 |
| 4 | small-q5_1 | 22/82 | 7:13, 0.263 | 0.258 | 0.089 | 0 | 0/197 | 0 | 190,085,487 |
| 5 | base | 4/82 | 0:24, 1.2e-07 | 0.363 | 0.143 | 0 | 0/197 | 0 | 147,951,465 |
| out | large-v3-q5_0 | 17/82 | 5:16, 0.027 | 0.211 | 0.086 | 1 | 0/197 | 0 | 1,081,140,203 |
| out | latam-q5_0 | 6/82 | 2:24, 1.1e-05 | 0.359 | 0.088 | 0 | 13/197 | 1 | 574,041,195 |

T10 (a), the most accurate model: turbo-q5_0 and turbo-q8_0 tie on accuracy. Their G1 counts are 28 and 25 of 82, and the discordant test gives 6:9, p 0.607. The G1 gap comes from the spelling of "Next.js": turbo-q5_0 found 10 of 11 and turbo-q8_0 found 1 of 11. Over all excerpts, turbo-q5_0 writes "Next" 11 times and "Next.js" once, and turbo-q8_0 writes "Nex" or "nex" 10 times. The reference WER does not separate them either (0.117 against 0.113 over all sets). Without the Next.js and React rows, the G1 order is turbo-q8_0 17, large-v3-q5_0 15, medium-q5_0 13, turbo-q5_0 11, and small-q5_1 11. Size and net RTF break the tie for turbo-q5_0: 574 MB against 874 MB, and a net RTF of 0.96 against 0.99. This is the catalog entry **Most Accurate**.

T10 (b), a catalog proposal: no model meets the rule. A candidate must pass the loop, WPM, and dropped-bin checks. It must also either beat a catalog entry on G1 (p below 0.05) at a net RTF of 1.2 times that entry or less, or match it at a net RTF or a file size of 0.8 times that entry or less. The catalog entries are base (net RTF 0.19, 148 MB), small-q5_1 (0.52, 190 MB), and turbo-q5_0 (0.96, 574 MB). The candidates that pass the checks and are not in the catalog are medium-q5_0 and turbo-q8_0.

| Candidate | Against | G1 test | RTF ratio | Size ratio | Meets (b) |
|---|---|---|---|---|---|
| medium-q5_0 | turbo-q5_0 | 6:10, p 0.454: matches | 1.07 (needs 0.8 or less) | 0.94 (needs 0.8 or less) | No |
| medium-q5_0 | small-q5_1 | 4:2, p 0.688: matches | 1.96 | 2.84 | No |
| medium-q5_0 | base | 21:1, p 1.1e-05: better | 5.48 (needs 1.2 or less) | n/a | No |
| turbo-q8_0 | turbo-q5_0 | 6:9, p 0.607: matches | 1.03 | 1.52 | No |
| turbo-q8_0 | small-q5_1 | 15:12, p 0.701: matches | 1.89 | 4.60 | No |
| turbo-q8_0 | base | 21:0, p 9.5e-07: better | 5.28 | n/a | No |

Do not add medium-q5_0, turbo-q8_0, latam-q5_0, or large-v3-q5_0 to the catalog.

- No model beats turbo-q5_0 on G1. The only significant differences against it are the three worse models: base, large-v3-q5_0, and latam-q5_0.
- large-v3-q5_0 is out by the loop check: one loop, "mm hmm" six times on X2 track 2. It is probably real speech (see Known limits). It is also worse than turbo-q5_0 on G1 (p 0.027) at 2.0 times the net RTF.
- latam-q5_0 is out by the WPM check (X2: 142 words per minute against a median of 186) and by the dropped-bin check (13 bins against 0 for the baseline). It is worse than turbo-q5_0 on G1 (p 1.1e-05).

### Term table

Found over expected, for each G1, G2, and G3 term. A "-" means the external system has no expected occurrence of that term in set 2. Of the 19 G1 names, 6 are found by no model: TanStack Start, TanStack Query, vinext, Vercel, Bun, and OpenClaw.

| Term | base | large-v3-q5_0 | latam-q5_0 | medium-q5_0 | small-q5_1 | turbo-q5_0 | turbo-q8_0 | app-transcript | whisperkit-large-v3 |
|---|---|---|---|---|---|---|---|---|---|
| TanStack Start | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | - | - |
| TanStack Query | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | - | - |
| Next.js | 1/11 | 1/11 | 3/11 | 10/11 | 10/11 | 10/11 | 1/11 | - | - |
| vinext | 0/3 | 0/3 | 0/3 | 0/3 | 0/3 | 0/3 | 0/3 | - | - |
| Cloudflare | 0/13 | 2/13 | 0/13 | 0/13 | 0/13 | 0/13 | 3/13 | - | - |
| Vercel | 0/4 | 0/4 | 0/4 | 0/4 | 0/4 | 0/4 | 0/4 | - | - |
| React | 1/7 | 1/7 | 0/7 | 1/7 | 1/7 | 7/7 | 7/7 | - | - |
| Ryan Dahl | 0/2 | 0/2 | 0/2 | 1/2 | 1/2 | 0/2 | 0/2 | - | - |
| Deno | 0/12 | 1/12 | 0/12 | 1/12 | 1/12 | 1/12 | 1/12 | - | - |
| Anthropic | 0/1 | 1/1 | 0/1 | 0/1 | 0/1 | 1/1 | 1/1 | - | - |
| Bun | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | - | - |
| GitHub Copilot | 0/5 | 3/5 | 1/5 | 4/5 | 4/5 | 3/5 | 3/5 | 2/2 | 2/2 |
| Claude | 0/4 | 0/4 | 1/4 | 0/4 | 0/4 | 0/4 | 0/4 | 0/1 | 1/1 |
| ChatGPT | 1/5 | 1/5 | 0/5 | 0/5 | 0/5 | 1/5 | 1/5 | 0/4 | 4/4 |
| OpenClaw | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | - | - |
| Visual Studio Code | 0/2 | 2/2 | 0/2 | 1/2 | 0/2 | 2/2 | 2/2 | - | - |
| IntelliJ | 0/3 | 3/3 | 0/3 | 3/3 | 3/3 | 0/3 | 3/3 | - | - |
| webreactiva.com | 0/3 | 1/3 | 0/3 | 1/3 | 0/3 | 1/3 | 1/3 | 1/1 | 1/1 |
| tokens | 4/14 | 9/14 | 10/14 | 12/14 | 7/14 | 10/14 | 12/14 | 2/2 | 2/2 |
| skills | 5/5 | 5/5 | 4/5 | 5/5 | 5/5 | 5/5 | 5/5 | - | - |
| seniority | 0/1 | 1/1 | 0/1 | 1/1 | 0/1 | 0/1 | 0/1 | - | - |
| Codex | 1/2 | 1/2 | 1/2 | 2/2 | 2/2 | 2/2 | 2/2 | 1/1 | 1/1 |
| markdown | 0/1 | 1/1 | 0/1 | 1/1 | 0/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| prompts | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 1/1 | 1/1 |
| soft skills | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 0/1 | 1/1 |
| agente | 2/5 | 3/5 | 3/5 | 3/5 | 2/5 | 3/5 | 3/5 | 3/4 | 4/4 |
| IA | 1/15 | 14/15 | 0/15 | 12/15 | 12/15 | 14/15 | 12/15 | 10/11 | 11/11 |

- "Next.js" is the largest swing between models: 10 of 11 for turbo-q5_0, small-q5_1, and medium-q5_0, and 1 of 11 for turbo-q8_0, base, and large-v3-q5_0.
- "React" is the largest source of the turbo-q5_0 lead over small-q5_1: 6 of the 13 occurrences that only turbo-q5_0 finds.

### Loops and flags

- large-v3-q5_0: X2 track 2, "mm hmm" x6.
- latam-q5_0, WPM flag: X2, 142 words per minute against a median of 186.
- latam-q5_0, 13 dropped bins (model words against reference words in a 10 s bin):
  - X1: 170 to 180 s (14 against 33), 190 to 200 s (9 against 25), 200 to 210 s (7 against 25).
  - X2: 20 to 30 s (14 against 30), 120 to 130 s (4 against 24), 130 to 140 s (13 against 35), 140 to 150 s (4 against 26), 160 to 170 s (2 against 33), 170 to 180 s (1 against 33), 180 to 190 s (9 against 28).
  - X4: 50 to 60 s (14 against 32), 200 to 210 s (1 against 24), 210 to 220 s (3 against 29).
- app-transcript, external: W4, 20 to 30 s (8 words against 25).
- All other models: 0 loops, 0 WPM flags, 0 dropped bins.

### Speed and memory

Net RTF is the sum of the transcribe wall times, minus one check wall time for each call, divided by 213.08 s of audio. The check is `dirigible model check`, timed apart. Peak MB is the maximum resident set size over the speed pass and the accuracy pass.

| Model | Check s | t1 s | t2 s | Net RTF | Peak MB, speed pass | Peak MB, both passes | 60 min episode, 2 tracks |
|---|---|---|---|---|---|---|---|
| base | 3.73 | 10.75 | 36.46 | 0.19 | 490 | 539 | about 22 min |
| small-q5_1 | 10.03 | 23.92 | 107.28 | 0.52 | 658 | 700 | about 63 min |
| medium-q5_0 | 29.92 | 63.21 | 214.87 | 1.02 | 1207 | 1456 | about 123 min |
| turbo-q5_0 | 33.22 | 68.20 | 203.11 | 0.96 | 1163 | 1208 | about 115 min |
| turbo-q8_0 | 32.91 | 69.08 | 206.98 | 0.99 | 1463 | 1489 | about 118 min |
| latam-q5_0 | 33.08 | 65.42 | 643.87 | 3.02 | 1194 | 1281 | about 362 min |
| large-v3-q5_0 | 43.11 | 102.80 | 389.85 | 1.91 | 1966 | 2415 | about 229 min |

- The episode column is net RTF x 7200 s of track audio. It is an estimate from one 106.54 s excerpt. Speech density changes the time: t2 has 247 to 296 words and t1 has 11 to 23, and t2 takes 3 to 10 times longer on every model.
- The **Model** paragraph of `docs/guide.md` gives 1.5 times the clip length for **Most Accurate** on the same machine class. That value is the gross wall time of one 240 s clip in the probe of `docs/research/whisper.md` (base 0.25, small-q5_1 0.69, turbo-q5_0 1.54). The net RTF above subtracts the check from each call and uses another excerpt. The trial did not measure which difference causes the gap, so do not put the two values in one table.
- medium-q5_0 and turbo-q5_0 have about the same net RTF on this Mac (1.02 and 0.96). R2 estimated medium at about 3 times small. The measured ratio is 2.0 (1.02 against 0.52).

### Candidate default

The app sheet starts at small-q5_1 for Spanish and at base for each other language (`languageModel` in `Sources/DirigibleApp/TranscribeSheet.swift`).

Candidate: turbo-q5_0 is the candidate Spanish default for the sheet. The change waits for the human-corrected calibration slice (backlog item 1519). Keep small-q5_1 in the catalog as the faster choice.

The recommendation rests on set 1 alone. The set 2 reference is large-v3-turbo (see **Setup**), so set 2 cannot rank turbo-q5_0 against small-q5_1.

- Set 1: turbo-q5_0 0.166, small-q5_1 0.258. turbo-q5_0 has 36 % fewer word errors. The model that made the set 1 reference is not known.

The other measures point the same way. None favors small-q5_1:

- Term score: turbo-q5_0 28 of 82 G1, small-q5_1 22 of 82. The difference is not significant (13:7, p 0.263).
- LOFO: turbo-q5_0 0.126, small-q5_1 0.156.
- G2: 16 of 23 against 12 of 23. G3: 17 of 20 against 14 of 20.

The cost of turbo-q5_0 against small-q5_1 on this Intel Mac:

- 1.84 times the net RTF (0.96 against 0.52).
- A download of 574 MB against 190 MB.
- A peak of 1208 MB against 700 MB.

What can overturn it: the human-corrected calibration slice (backlog item 1519). If the WER gap comes from the pseudo-reference and not from the models, keep small-q5_1.

If the calibration slice confirms the candidate, the change is a feature run with a `Sources/` change. It touches `TranscribeSheet.languageModel` and its doc comment, the tests that expect `.catalog(.smallQ51)` for `es` in `Tests/DirigibleTests/TranscribeSheetTests+ModelFile.swift`, the **Model** paragraph of `docs/guide.md`, and decision 0065. Check the UI strings of decision 0010 when a title or a size text changes.

### CLI and MCP default

The CLI (`dirigible transcribe`, `Sources/DirigibleCLI/TranscribeCommand.swift`) and the MCP tool (`Sources/DirigibleMCP/TranscribeWork.swift`) use base for every language. The app sheet uses small-q5_1 for Spanish. On this Spanish corpus, base has 4 of 82 G1 and a WER of 0.363 (set 1) and 0.143 (set 2). It is the worst of the eligible models. **CLI parity** in decision 0011 requires a command for each feature, not the same default, so this gap breaks no written rule. A feature run decides whether the CLI and MCP default follows the sheet.

### latam-q5_0 speed

latam-q5_0 took 643.87 s wall and 2519.62 s user CPU on S1 track 2. turbo-q5_0 took 203.11 s and 821.21 s. Both models have the same architecture and the same file size.

- Machine load does not explain it. latam-q5_0 retired 16.6e12 instructions against 4.68e12 (3.55 times). The instructions per cycle are the same (2.03 against 2.07), and so is the CPU time over the wall time (3.91 against 4.04). Load makes a call wait longer. It does not add retired instructions. So latam-q5_0 did about 3.5 times more work.
- The extra work repeats in the accuracy pass. The ratio of user CPU (latam-q5_0 over turbo-q5_0) is 2.1 to 5.6 on 7 of the 8 X tracks (X4 track 1: 1.3), 2.3 on W1, 1.0 to 1.3 on W2 to W4, and under 1.0 on E1.
- The excerpts with the extra work are the excerpts where latam-q5_0 drops speech. In X2 track 2, one word starts at 142.5 s and lasts 38.7 s, and the model has 4 words in 150 to 200 s where turbo-q5_0 has 96. In X2 track 1, one word starts at 11.2 s and lasts 140.7 s. latam-q5_0 also writes no space after a full stop, so two words join.
- The cause is not known. Hypothesis: the fine-tune makes whisper.cpp decode some segments again (temperature fallback), and the model then skips speech with a long timestamp jump. A run on S1 track 2 with the whisper.cpp decoder log (the fallback count of each segment) can confirm or refute it. The result does not change: latam-q5_0 fails the WPM and dropped-bin checks.
- U10 of the plan stays open: the tester accent may not match this fine-tune, which trained on Common Voice 17 es without accents from Spain (R3).

### Known limits

- Term score power. There are 82 G1 occurrences, 73 in set 1 and 9 in set 2. The paired binomial treats each occurrence as independent. The occurrences of one name in one excerpt are not independent: "React" has 6 occurrences in X1, and 6 of the 13 occurrences that only turbo-q5_0 finds against small-q5_1 are "React". Six of the 19 G1 names are found by no model, and Cloudflare is found by 2 of 7 models. The best model finds 34 % of the G1 occurrences. So the term score separates only the large gaps: base, latam-q5_0, and large-v3-q5_0 from turbo-q5_0.
- Turbo reference. The set 2 reference is large-v3-turbo, so a set 2 WER that ranks two models needs a reference that neither model made. No set 2 WER ranks turbo-q5_0, turbo-q8_0, or latam-q5_0 against another model.
- Shared encoder. turbo-q5_0, turbo-q8_0, latam-q5_0, large-v3-q5_0, and the WhisperKit reference vote as one family. So the LOFO value of these models comes from base, small-q5_1, medium-q5_0, and on set 2 the app transcript: weaker voters. The LOFO value is a weak tie-break.
- The app transcript has no model name. If a large-v3-encoder model made it, it gives agreement to the four large-v3-encoder candidates on set 2.
- The reference is not a human transcript. It keeps the errors of the tester Whisper run that no regex fixed, so a model that hears a word right can count as wrong. A regex can also over-correct: `\bcloud\b` becomes "Claude", and a bare "Next" is the inference of the tester. So the WER against the tester text is an upper limit of the model error. No measure here has a measured link to the true WER (R9).
- Misspellings count the keys of the corrections files. These keys are the errors of the tester Whisper run, so a model near that run gets more counts (turbo-q5_0 40, small-q5_1 33). The ranking does not use this column.
- The term match window is the cue plus 2 s on each side. Whisper word starts can be up to about 1 s early with VAD (decision 0065 D7). The self-test used exact times, so a term with a low found count and many extra hits in the same excerpt can be a window miss and not a spelling miss.
- The dropped-bin rule flags a drop that fills a bin, or covers 7.5 s or more of one bin. A drop of 10 s that falls in halves over two bins can pass. The reference words spread evenly over each cue, so a long cue moves some words to a neighbor bin.
- The loop of large-v3-q5_0 is probably real speech. The six "Mm-hmm." words are separate, from 218.2 s to 245.6 s (27.4 s) on the listener track, and medium-q5_0 writes "Mm hmm" two times in the same span. The loop rule checks only that the n-grams are back to back, not the time between them. This does not change the ranking.
- Speed comes from one machine (Intel Core i5-8259U, CPU only, no Metal) and one 106.54 s excerpt. Results on Apple silicon with Metal can differ (see `docs/research/metal.md`).
- Only Spanish audio ran. The trial gives no evidence for other languages.
- Out of scope, each a backlog item: `initial_prompt` variants (1518, needs a `Sources/` change), the human-corrected calibration slice (1519), Parakeet and Canary (1520), and Metal (1517).

## Sources

- `Sources/CWhisper/src/whisper.cpp` and `Sources/CWhisper/include/whisper.h` (vendored v1.9.5): lines cited in R1, R14, R15.
- `Sources/DirigibleAudio/Transcribe/WhisperEngine.swift` lines 105 to 116 (parameters set by the app).
- `Sources/CWhisper/README.dirigible` (list of vendored files).
- `docs/research/whisper.md` (Date 2026-10-28): F18, F21, F30, F31, line 275, P2, P11.
- `docs/decisions/0065-whisper-transcription.md`.
- whisper.cpp tag `v1.9.5` (commit `d2a764c648779feb36d44363f212a29b00aad1af`): `https://github.com/ggml-org/whisper.cpp/tree/v1.9.5`, files `models/convert-h5-to-ggml.py`, `models/convert-parakeet-to-ggml.py`, `include/parakeet.h`, `src/parakeet.cpp`, `examples/parakeet-cli/README.md`, `examples/cli/cli.cpp`, `scripts/upload-parakeet.py`. Release notes `https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5`.
- Hugging Face API, read 2026-11-03: `https://huggingface.co/api/models/ggerganov/whisper.cpp` and `/tree/main`; `.../openai/whisper-large-v3`, `.../openai/whisper-large-v3-turbo`, `.../openai/whisper-medium`; `.../handy-computer/whisper-{tiny,base,small,medium,large-v2,large-v3,large-v3-turbo}-gguf` (README, `transcribe_cpp` WER fields); `.../marianbasti/whisper-large-v3-turbo-latam`; `.../JoaoZaokk/whisper-large-v3-turbo-latam-ggml`; `.../adriszmar/whisper-large-v3-turbo-es`; `.../Sendery/whisper-large-v3-turbo-es-ggml`; `.../HiTZ/whisper-large-v3-es`; `.../zuazo/whisper-large-v3-es`; `.../marianbasti/distil-whisper-large-v3-es`; `.../UNRN/distil-whisper-large-v3-es`; `.../BSC-LT/whisper-large-v3-LoS-punctuated`; `.../Teltek/whisper-ggml-iberian`; `.../deepdml/whisper-medium-mix-es`; `.../distil-whisper/distil-large-v3`, `distil-large-v3.5`, `distil-large-v2`, `distil-medium.en`, `distil-small.en`, `distil-large-v3-ggml`, `distil-large-v3.5-ggml`; `.../efficient-speech/lite-whisper-large-v3-turbo-acc`; `.../nvidia/parakeet-tdt-0.6b-v3`; `.../nvidia/canary-1b-v2`; `.../ggml-org/parakeet-GGUF`; `.../mudler/parakeet-cpp-gguf`. Search calls: `https://huggingface.co/api/models?search=whisper&filter=es&sort=downloads`.
- Fiscus, "A post-processing system to yield reduced word error rates: Recognizer Output Voting Error Reduction (ROVER)", IEEE ASRU 1997: text at `https://people.csail.mit.edu/joe/sctk-1.2/doc/rover/rover.htm`.
- "Automatic Quality Estimation for ASR System Combination", arXiv 1706.07238 (abstract). "Driving ROVER with Segment-based ASR Quality Estimation", ACL 2015 (`https://aclanthology.org/P15-1106.pdf`, listed in search, not read).
- "On the Robust Approximation of ASR Metrics", ACL Findings 2025: `https://aclanthology.org/2025.findings-acl.1187/` (abstract only).
- "Generative vs. Encoder Large Language Models for ASR Evaluation: A Comparative Study", arXiv 2608.25574 (HTML version, Table II).
- NoRefER, arXiv 2306.12577 and 2306.13114 (Table 1 and Table 2 of the HTML version).
- "Aligning ASR Evaluation with Human and LLM Judgments", arXiv 2506.16528 (abstract).
- "Improving Rare-Word Recognition of Whisper in Zero-Shot Settings", arXiv 2502.11572 (abstract).
- Contextual biasing metrics: arXiv 2406.16120 (names B-WER and U-WER, cites Le et al., Interspeech 2021). Conformer-1, arXiv 2404.07341 (by search summary only).
- OpenAI cookbook, "Whisper prompting guide": `https://developers.openai.com/cookbook/examples/whisper_prompting_guide`. OpenAI speech-to-text guide: `https://developers.openai.com/api/docs/guides/speech-to-text`. `openai/whisper` `whisper/transcribe.py` (GitHub contents API, default branch).
- Whisper paper (Radford et al., arXiv 2212.04356): through F30.
- Hugging Face file `argmaxinc/whisperkit-coreml`, `openai_whisper-large-v3-v20240930/config.json`, read 2026-11-07: `decoder_layers` 4 and `_name_or_path` ending in `tmp_whisper_turbo` (large-v3 has 32 decoder layers; turbo has 4).
- Trial data: the graded outputs of run `2026-11-03-whisper-model-trial` (grades, term table, speed rows, and logs). The run folder is outside git. The audio and the tester SRT files are not in this repo.
