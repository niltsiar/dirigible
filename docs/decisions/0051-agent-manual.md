# 0051. The agent manual: one owner for the MCP instructions, the prompts, the skill, and `dirigible --instructions`

- Status: accepted
- Date: 2026-10-13
- Date accepted: 2026-10-13, after plan gates 1 and 2 of run `2026-10-13-agent-onboarding`.
- Amends: 0041 (the server sends `instructions` and serves `prompts/list` and `prompts/get`), 0011 (CLI parity: the root flag `--instructions` and the command `skill` are not package features, so they get no tool).
- Amended: 2026-10-13, run `2026-10-13-agent-workflows`. The manual follows the phases of the work: prepare, record, edit, produce, export. `AgentManual.Phase` owns the order and the record rule; each recipe has a phase, and the core gives one line for each phase. Seven recipes: `prepare-tracks`, `cut-a-range`, `cut-from-transcript`, `check-levels`, `add-sound`, `add-chapter`, `prepare-for-publishing`. Frames can come from a transcript. The recipes name the `loudness` and `export` tools; `level` and `import` stay CLI lines until their tools land. The core says that noise reduction and a voice profile do not exist yet.
- Amended: 2026-10-14, run `2026-10-13-ripple-ranges`, by a lead ruling of upkeep run 2026-10-14. The core cut of 2048 characters stays. The whole text is a context-cost cap, not a client cut, so its limit moves from 4000 to 6000 characters.
- Amended: 2026-10-14, run `2026-10-13-transcript-1` (see 0055). The `cut-from-transcript` recipe uses the transcript tools in place of the frame math: `transcript_import` with `path` first, `transcript_words` with `match`, the consent of the user, and one `transcript_cut`. It says that the words follow the clips of the import track.
- Amended: 2026-10-17, run `2026-10-17-agent-pack`. `add-sound` shapes the clip in one `import` call, and places more parts of one file with `clip_place` and the file ID, because each import converts the whole file. `add-chapter` names `chapters_import`. `prepare-for-publishing` names `chapters_export` with a `.txt` file and `file_prune` with `dry_run`. `cut-a-range` heals the splits that stay with `clip_heal`. The reading lines name `session_info` with `compact`. The whole text stays at 6000 characters.
- Amended: 2026-10-19, run `2026-10-18-envelope-ducking` (see 0060). Eight recipes: `lower-music` (produce) lowers a music clip under a voice with `clip_gain_range`. The core and the whole text are at their caps, so `clip_envelope` is in the tool list only.
- Amended: 2026-10-23, run `2026-10-23-read-by-time` (see 0062). The core says "`silences`, `nearest_pause`, and `meter` read audio by time." in place of the rule that no tool reads the audio by time.
- Amended: 2026-10-24, run `2026-10-23-read-by-time`. The core ends its edit rule with "Saves keep backups: `backup_list`." The `backup_list` and `backup_revert` texts and `dirigible backup list --help` give the rule of 0043 with the values of `BackupPolicy`.
- Amended: 2026-10-26, run `2026-10-13-replace-roomtone-split` (see 0053). `clip_split_stereo` is in the tool list only: the skill table takes its description from the tool table, and no recipe names it.
- Amended: 2026-10-26, run `2026-10-13-render-denoise` (see 0054). `clip_denoise` is in the tool list only: no recipe names it, because the core and the whole text have no room. The core has one line for Match Voice (`track_match_voice`, see 0074), and its arguments are in the skill only (`AgentManual.matchLine`).
- Amended: 2026-10-27, run `2026-10-27-agent-change-only-asked`. The core starts its rules with "Change only what the user asks for. Ask before other changes." The time rule drops the sentence on the `to` frame. Each exclusive `to` argument states the rule. `clip_heal` and the `session_info` filter are not exclusive (item 1093). The core is 2040 of 2048 characters and the whole text 5974 of 6000 (the Swift `count` of `theCoreFitsTheClientLimit`).
- Amended: 2026-10-28, run `2026-10-14-render-link` (see 0057). `clip_restore` is in the tool list only: the skill table takes its description from the tool table, and no recipe names it, because the core and the whole text have no room.
- Amended: 2026-10-29, run `2026-10-27-repair-set` (see 0064). `clip_repair` is in the tool list only: the skill table takes its description from the tool table, and no recipe names it, because the core and the whole text have no room.
- Amended: 2026-11-01, run `2026-10-28-silence-tool` (see 0066). `silence_edit` is in the tool list only: the core and the whole text have no room.
- Amended: 2026-11-06, run `2026-10-28-timeline-edits` (see 0011 and 0036). `clip_close_gaps`, `clip_roll`, and `clip_slip` are in the tool list only: the skill table takes their description from the tool table, and no recipe names them, because the core and the whole text have no room.
- Amended: 2026-11-18, run `2026-10-28-waveform-sync` (see 0076). The skill table names the tool `clip_sync` with the command `dirigible clip sync`. Its arguments and its one-lag limit are in the skill only (`AgentManual.syncLine`), with no result line: `dirigible help clip sync` gives those.
- Amended: 2026-11-20, run `2026-10-28-stem-export` (see 0078). `export_stems` is in the tool list only: no recipe names it, because the core and the whole text have no room. The skill table names it with `dirigible export-stems`, and the skill role line names the role stems.
- Amended: 2026-11-21, run `2026-10-28-presets-templates` (see 0079). `session_create` takes the argument `template`, with `sample_rate` optional: the tool description carries both arguments, and the core and the recipes do not change. The skill table names it with `dirigible create`, which takes `--template`.

## Context

R16: agents read and edit sessions through `dirigible mcp`. A tester asked for "a skill to know how to use the MCP". The server sent only the tool list. A baseline eval with `claude -p` (run `2026-10-13-agent-onboarding`, eval E38) showed that agents do each single edit well from the tool descriptions. They fail where no tool exists. With a shell, they cannot find the CLI: it is not on `PATH`, and they do not know its path in the app. Claude Code, Codex, and opencode read the `instructions` of the server. Claude Code and opencode serve MCP prompts as commands. Claude Code reads skills in `~/.claude/skills`; Codex, opencode, and Cursor read `~/.agents/skills` (`docs/research/agent-onboarding.md`). Hindenburg PRO has no agent interface.

## Decision

- **One owner.** `AgentManual` in `DirigibleMCP` holds the manual: the core rules, then one line for each recipe. The MCP `instructions` (both eras), `dirigible --instructions`, the prompts, and the skill take their text from it. A test fails when the text names a tool, a tool argument, or a `dirigible` command line that does not exist or does not parse.
- **The CLI path.** The instructions and `--instructions` name the absolute path of the running `dirigible` once, after symlinks. So an agent with a shell can run the commands that have no tool. The skill names the path rule instead: resolve the skill folder with `realpath`, then run `Contents/Helpers/dirigible` of that app. For a copy of the skill, run `/Applications/Dirigible.app/Contents/Helpers/dirigible`, or ask the user.
- **The CLI record.** The manual shows `dirigible record` as a capability with a plain warning: it records at once from the routed devices, with no consent sheet. Run it only when the user asked for a recording. The `record` tool asks the user in the app (R16, 0048). A test fails when the example or its warning drops. Hiding a real capability does not stop abuse: the permission rules of the agent client are the gate (user decision, 2026-10-13). The agent eval runs each agent inside the probe sandbox with no audio server.
- **Length.** The core rules are 2048 characters or less (the documented cut of Claude Code). The whole text is 6000 characters or less.
- **`dirigible --instructions`.** A flag of the root command prints the manual, exit 0. `dirigible`, `dirigible help`, and `dirigible --help` print the help as before. The parser ignores the flag after a subcommand.
- **Prompts.** Each recipe is an MCP prompt with one required argument, `package`. `prompts/get` gives one user message: the recipe with the package path. An unknown name or no `package` gives -32602.
- **Skill.** `dirigible skill show` prints the `SKILL.md` text (frontmatter `name: dirigible` and `description`). `scripts/bundle.sh` writes it to `Contents/Resources/skills/dirigible/SKILL.md` before the signature, so the file always matches the app version. `dirigible skill path` prints the path of that file, exit 0. It exits 1 when no app holds the binary. The user links the folder into `~/.claude/skills` or `~/.agents/skills`.
- **The skill works with no MCP server.** The skill gets a table of each tool and its `dirigible` command, made from the tool table and the name rule of 0041, so a new tool shows up with no hand edit. A test fails when a tool or a command is named nowhere in the manual, the recipes, or the table, and has no exemption with a reason. Each later run keeps the manual, the recipes, and the skill current, as it keeps the guide current (user rule, 2026-10-13).
- **Copy Setup Command** does not change.

## Consequences

- A new tool or a renamed argument that the manual names fails the manual test until the text changes.
- The run that adds the long tools (run 7b) changes the recipe lines that name `dirigible level`, `loudness`, and `export` to the tools.
- A moved app gives a new path in the instructions at the next start of the server. A skill link to a moved app breaks; the guide says to link it again.
- `ParityTests` lists `skill path` and `skill show` with no tool: they read no package.

## Alternatives considered

- Typed text with tool placeholders that render a tool or a command by `Tool.all`: it switches to the long tools by itself, but each author must learn the text type.
- A committed `SKILL.md` with an equality test: a copy that each text edit must make again.
- An MCP resource for the manual: each client of the research table reads the instructions already.
- Put the manual in `dirigible --help`: the user kept `--help` for people.

## Sources

- `docs/research/agent-onboarding.md` (2026-10-13).
- Run `2026-10-13-agent-onboarding`: probes p1 (the root flag) and p2 (the instructions length), the baseline and the prototype of eval E38.
