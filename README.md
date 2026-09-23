# Dirigible

Dirigible is a podcast recorder and editor for macOS 14 Sonoma and later. It records several microphones and audio interfaces at the same time, each to its own track, without a macOS aggregate device. It is modeled on Hindenburg PRO.

Status: the project is new. The build, the tests, and the agent workflow are ready. The recorder and the editor are not built yet. `docs/requirements/brief.md` lists what the app will do.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel.
- To build from source: Xcode 26 or later (Swift 6.2). You do not need an Apple developer account.

## Build and run

```sh
git clone https://github.com/niltsiar/dirigible.git
cd dirigible
```

```sh
make setup   # once per clone: enables the pre-commit hook
make run
```

`make run` builds `build/Dirigible.app` and opens it. Other commands:

| Command | What it does |
|---|---|
| `make app` | Builds `build/Dirigible.app`, universal and ad-hoc signed. |
| `make test` | Runs the tests. |
| `make check` | Runs the format check, the tests, and the checks on the built app. |
| `make format` | Formats the Swift code. |

## Keep the microphone permission across builds

macOS links the microphone permission to the code signature of the app. The default ad-hoc signature changes on every build, so macOS can ask for the permission again after a rebuild. To stop this, sign with a local certificate:

1. Open Keychain Access. Select **Keychain Access > Certificate Assistant > Create a Certificate**.
2. Enter the name `Dirigible Local`, set **Certificate Type** to **Code Signing**, and click **Create**.
3. Build with the certificate:

   ```sh
   SIGN_IDENTITY="Dirigible Local" make run
   ```

## Open a downloaded build

The app is not notarized, because the project has no Apple developer account. macOS blocks the first launch of a downloaded copy.

- On macOS 14: Control-click the app, select **Open**, then click **Open** again.
- On macOS 15 and later: open the app once, then go to **System Settings > Privacy & Security** and click **Open Anyway**.
- From Terminal, on any version: `xattr -dr com.apple.quarantine /Applications/Dirigible.app`

A build that you make on your own Mac does not get this block.

## How the project works

Agents and humans follow the same rules. `AGENTS.md` has the commands, the architecture rules, the testing rules, and the git rules. Every feature goes through the `deliver` flow: analyze, plan, review, implement test-first, review, verify, land, and reflect. Decision records are in `docs/decisions/`.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
