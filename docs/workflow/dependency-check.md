# Dependency check

The procedure of the periodic check of the dependencies and the Whisper models. `.claude/skills/deliver/scripts/new-run.sh` prints `dependency check due` when the `Last check:` date below is 30 or more days old, or when the line is not valid. The dependency inventory item of the wiki holds the inventory and the history of the checks (`scripts/wiki.py list <status>` shows its id).

Last check: 2026-11-02

## Run rule

- A due check becomes one dependency check item with status next, and runs before the next product item. `new-run.sh` prints the due line until the new `Last check:` date lands on main.
- The run that takes the item runs the check in one lock-free agent, and commits the new `Last check:` line on its branch. The check is read-only: it builds nothing, runs no test, and changes no pin.
- The check is done when each pin has a result from each source, the inventory item has the new History line, and the `Last check:` line has the date of the check.

## Pins to read

- `Package.resolved`: the Swift packages and their versions.
- `Sources/CWhisper/README.dirigible`: the vendored whisper.cpp release and the SHA-256 of its tarball.
- `Sources/CLame/README.dirigible`: the vendored LAME release and the SHA-256 of its tarball.
- `Sources/DirigibleAudio/Transcribe/WhisperModel.swift`: the catalog models, with the Hugging Face revision, the byte count, and the SHA-256 of each model.
- `Sources/DirigibleAudio/Transcribe/TranscribeJob.swift`: the VAD model, with its byte count and SHA-256.

## Sources

For each pin, read each source that applies:

- The GitHub security advisories of the upstream repo.
- OSV.dev, for the package and the pinned version.
- The release page of the upstream project: each release or tag after the pin.
- The Hugging Face repo of each model pin: a revision after the pin, and each new or changed file.
- A HEAD request of each pinned model URL. Follow the redirect, and compare the size and the SHA-256 that the response gives with the pin.

## Classes

Put each finding in one class:

- **security**: a vulnerability in a code path that the app runs, for example the parse of a model file that the user picks.
- **bug**: a fixed defect of a pinned dependency that the app can hit.
- **improvement**: a new version or a new model that can make the app faster or better.
- **not relevant**: a change in code that the app does not vendor or call.

## Writes

1. Add one dated History line to the dependency inventory item: `scripts/wiki.py show <id>`, then `scripts/wiki.py edit <id> --from <file> --expect <hash>`. The line gives each finding with its class, or says that the check found none.
2. For each security finding, add an item with status next (`scripts/wiki.py add next --from <file>`). It goes before the next product item. For each bug or improvement that the app can use, add an item with status later.
3. Change the `Last check:` line above to the date of the check, and commit it on the branch of the run that takes the item.
