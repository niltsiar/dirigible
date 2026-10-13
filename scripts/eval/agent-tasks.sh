#!/bin/bash
# Run the agent eval E38 (docs/workflow/evals.md): headless Claude Code runs that edit a generated
# session with the dirigible MCP tools, the CLI, or the bundled skill. Then grade them.
# Usage: scripts/eval/agent-tasks.sh <dirigible binary> <results folder> <model> <label> [<task>...]
#   The tasks are T1 to T8 (default: all). Put the results folder in the eval/ folder of the run.
#   SHELL_CLI=1 also gives Bash, allowed for the copied CLI only (the shell variant).
#   SKILL_LINK=<app> gives no MCP server, but Bash and the Skill tool, and links the skill folder
#   of <app> as .claude/skills/dirigible in the task cwd (the skill variant).
# Each task runs in a new folder under /private/tmp, outside the repo, so no CLAUDE.md, AGENTS.md,
# setting, or hook of the repo reaches the agent. The whole claude run is inside
# scripts/probe.sh --no-audio of that folder: the agent, its Bash commands, and the MCP server write
# only there, open no audio device, and reach no app (the socket path has no listener). The runner
# copies stream.jsonl, after.json, after.stderr.txt, out.txt, stderr.txt, and variant to
# <results>/<label>/<task>/, then deletes the task folder. A smoke task (T4, MCP only) runs first;
# the batch stops when it does not pass. scripts/eval/agent-grade.py grades the runs, also each
# init message.
set -euo pipefail
[[ $# -ge 4 ]] || { sed -n '4,8p' "$0" >&2; exit 2; }
bin="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")" model="$3" label="$4"
mkdir -p "$2"
results="$(cd "$2" && pwd -P)"
shift 4
tasks=("$@")
[[ $# -gt 0 ]] || tasks=(T1 T2 T3 T4 T5 T6 T7 T8)
here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
probe="$repo/scripts/probe.sh"
# The skill link and the allow rule need the real absolute path of the app.
app=""
[[ -z ${SKILL_LINK:-} ]] || app="$(cd "$SKILL_LINK" && pwd -P)"
[[ -z $app || -f "$app/Contents/Resources/skills/dirigible/SKILL.md" ]] || { echo "agent-tasks.sh: no skill in $app" >&2; exit 2; }

prompt() {
    case "$1" in
        T1) echo 'In the Dirigible session {S}, level all clips and tell me the loudness of each clip.' ;;
        T2) echo 'In the Dirigible session {S}, trim the silence at the start of the host track.' ;;
        T3) echo 'In the Dirigible session {S}, add a chapter named "Gear talk" at minute 1.' ;;
        T4) echo 'In the Dirigible session {S}, rename the tracks: Track 1 is the host, Ana, and Track 2 is the guest, Ben.' ;;
        T5) echo 'Export the episode in the Dirigible session {S} as an MP3 file into the folder {OUT}.' ;;
        T6) echo 'In the Dirigible session {S}, cut the part from 0:30 to 0:40 out of the episode, and keep the host and the guest in sync.' ;;
        T7) echo 'Prepare the episode in the Dirigible session {S} for publishing as an MP3 file in the folder {OUT}. The title is "Home studios" and the show is "Gear Talk".' ;;
        T8) echo 'In the Dirigible session {S}, record 10 seconds on the host track.' ;;
        *) echo "agent-tasks.sh: no task $1" >&2; return 2 ;;
    esac
}

for task in "${tasks[@]}"; do prompt "$task" >/dev/null; done

# The session of all tasks, made once per batch in its own folder.
base="$(mktemp -d /private/tmp/dirigible-e38-XXXXXX)"
trap 'rm -rf "$base"' EXIT
"$probe" --no-audio "$base" bash "$here/agent-session.sh" "$bin" >"$base/session.log" 2>&1 \
    || { cat "$base/session.log" >&2; exit 1; }
# Each batch makes a new session, so its pristine session is named by its label.
"$bin" info "$base/Show.dirigible" --json >"$results/pristine-$label.json"
cp "$results/pristine-$label.json" "$results/pristine-smoke-$label.json"

# run_task <task> <label> <variant>: one claude run in a new task folder.
run_task() {
    local task="$1" out="$results/$2/$1" variant="$3" t
    # In the batch folder, so the trap removes it also after a failure or an interrupt.
    t="$(mktemp -d "$base/task-XXXXXX")"
    mkdir -p "$t/out" "$t/tmp" "$t/cwd" "$out"
    cp -R "$base/Show.dirigible" "$t/Show.dirigible"
    cp "$bin" "$t/dirigible"
    local text
    text="$(prompt "$task")"
    text="${text//\{S\}/$t/Show.dirigible}"
    text="${text//\{OUT\}/$t/out}"
    local tools=(--tools "") allowed=(--allowedTools mcp__dirigible)
    printf '{"mcpServers": {"dirigible": {"command": "/usr/bin/env", "args": ["DIRIGIBLE_MCP_SOCKET=%s/no-app.sock", "%s/dirigible", "mcp"]}}}\n' \
        "$t" "$t" >"$t/mcp.json"
    if [[ $variant == shell ]]; then
        tools=(--tools Bash) allowed=(--allowedTools mcp__dirigible "Bash($t/dirigible:*)")
    elif [[ $variant == skill ]]; then
        echo '{"mcpServers": {}}' >"$t/mcp.json"
        mkdir -p "$t/cwd/.claude/skills"
        ln -s "$app/Contents/Resources/skills/dirigible" "$t/cwd/.claude/skills/dirigible"
        tools=(--tools Bash,Skill) allowed=(--allowedTools Skill "Bash(realpath:*)" "Bash($app/Contents/Helpers/dirigible:*)")
    fi
    # --setting-sources project drops the user plugins and hooks, which changed the answers.
    # --strict-mcp-config keeps the claude.ai connectors out. CLAUDE_CODE_TMPDIR sets the Bash temp folder.
    "$probe" --no-audio "$t" /bin/sh -c 'cd cwd && exec "$@"' sh \
        env CLAUDE_CODE_TMPDIR="$t/tmp" TMPDIR="$t/tmp" claude -p "$text" --model "$model" \
        --mcp-config "$t/mcp.json" --strict-mcp-config --setting-sources project "${tools[@]}" "${allowed[@]}" \
        --output-format stream-json --verbose --no-session-persistence \
        </dev/null >"$out/stream.jsonl" 2>"$out/stderr.txt" || echo "claude exit $?" >>"$out/stderr.txt"
    "$t/dirigible" info "$t/Show.dirigible" --json >"$out/after.json" 2>"$out/after.stderr.txt" || true
    ls -la "$t/out" >"$out/out.txt"
    echo "$variant" >"$out/variant"
    rm -rf "$t"
}

variant=mcp
[[ "${SHELL_CLI:-}" == 1 ]] && variant=shell
[[ -n $app ]] && variant=skill
run_task T4 "smoke-$label" mcp
smoke="$(python3 -I "$here/agent-grade.py" "$results" "smoke-$label" | awk -F'\t' -v l="smoke-$label" '$1 == l && $2 == "T4" { print $4 }')"
[[ $smoke == pass ]] || { echo "agent-tasks.sh: the smoke task T4 is $smoke, not pass; no batch" >&2; exit 1; }
pids=()
for task in "${tasks[@]}"; do
    run_task "$task" "$label" "$variant" &
    pids+=("$!")
done
failed=()
for i in "${!pids[@]}"; do wait "${pids[$i]}" || failed+=("${tasks[$i]}"); done
python3 -I "$here/agent-grade.py" "$results" "$label"
[[ ${#failed[@]} -eq 0 ]] || { echo "agent-tasks.sh: the runner failed on ${failed[*]}" >&2; exit 1; }
