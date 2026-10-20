#!/bin/bash
# Run a whole eval of docs/workflow/evals.md: the doc sets, the questions, the answer sessions, the
# quote check, the blind graders, the scores, and the verdict. Each session is a headless claude
# call with the tools Read and Write only, started in a new temporary folder outside the checkout
# (a CLAUDE.md of the checkout would load in a session that starts under it), and with --safe-mode
# (no CLAUDE.md of the operator, no skill, no hook). An agent session needs the skills and the
# CLAUDE.md of its docs copy: it excludes only the global CLAUDE.md, with claudeMdExcludes.
# An answer session reads its docs copy and its question file, and writes its answer file; a grader
# reads its packet and writes its result file. keys.md comes after the answer sessions.
# Usage: scripts/eval/run.sh <eval folder> <old commit> <new commit> <ID,ID,...> <tag> [--holdout-keys <keys.md>]...
#   The eval folder is under .scratchpads/ or $TMPDIR. Set a is the old commit, set b the new one.
#   Each docs copy has a stamp logs/build-<set>.commit. A copy is not built again when its log ends
#   with "byte check end" and its stamp is the resolved commit. Else the runner exits 2.
#   Each tag has its answers in <eval folder>/answer-<tag>/. A folder with a file exits 2.
#   keys.md is the Key points cells of the Scenarios table. A holdout row has its key in the first
#   --holdout-keys file that has a "## <ID>" line, followed by one line of the key points.
#   A row of type agent that has a quoted prompt and no task in agent-tasks.sh (E41) runs RUNS
#   sessions of ANSWER_MODEL, each in a copy of set b under /private/tmp. The same grader scores
#   them in <eval folder>/agent/. The runner prints the score rows; the pass rule of the row is
#   for the caller.
#   E38 runs through scripts/eval/agent-tasks.sh.
# Env: RUNS (3), ANSWER_MODEL (sonnet), GRADER_MODEL (opus).
# Exit: 0 verdict PASS (or the agent rows scored), 1 verdict FAIL, 2 bad input, 3 a session or a
# check failed. A failed session stops the sessions that still run. An INT or TERM stops them all.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
evals_md="$repo/docs/workflow/evals.md"
RUNS="${RUNS:-3}"
ANSWER_MODEL="${ANSWER_MODEL:-sonnet}"
GRADER_MODEL="${GRADER_MODEL:-opus}"

die() { echo "run.sh: $2" >&2; exit "$1"; }

holdout_files=()
pos=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --holdout-keys)
            [[ $# -ge 2 && -f $2 ]] || die 2 "--holdout-keys needs a file"
            holdout_files+=("$2")
            shift 2
            ;;
        *) pos+=("$1"); shift ;;
    esac
done
[[ ${#pos[@]} -eq 5 ]] || { sed -n 's/^# //; /^Usage:/p' "$0" >&2; exit 2; }
[[ $RUNS =~ ^[1-9][0-9]*$ ]] || die 2 "RUNS is $RUNS, not a number"
command -v claude >/dev/null || die 2 "the command claude is not on PATH"
mkdir -p "${pos[0]}"
eval_dir="$(cd "${pos[0]}" && pwd -P)"
tag="${pos[4]}"
[[ $tag =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "the tag $tag has other characters than letters, digits, - and _"
hash_a="$(git -C "$repo" rev-parse --verify --quiet "${pos[1]}^{commit}")" || die 2 "no commit ${pos[1]}"
hash_b="$(git -C "$repo" rev-parse --verify --quiet "${pos[2]}^{commit}")" || die 2 "no commit ${pos[2]}"

# One line for each ID: ID, type, key points, quoted prompt of the question; the fields are
# separated by the unit separator, so an empty field stays.
table="$(python3 -I -c '
import re, sys
rows, section = {}, ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("## "):
        section = line[3:].strip()
    if section == "Scenarios" and re.match(r"\| [EH][0-9]+ \|", line):
        c = [x.strip().replace("\\|", "|") for x in re.split(r"(?<!\\)\|", line)]
        m = re.search(r"with the prompt: \"([^\"]*)\"", c[4])
        rows[c[1]] = (c[2], c[5], m.group(1) if m else "")
ids = sys.argv[2].split(",")
absent = [i for i in ids if i not in rows]
if absent:
    sys.exit("no Scenarios row for " + " ".join(absent))
for i in ids:
    print("\x1f".join([i, *rows[i]]))
' "$evals_md" "${pos[3]}")" || die 2 "${pos[3]}: see above"

doc_ids=() doc_keys=() agent_id="" agent_key="" agent_prompt=""
while IFS=$'\037' read -r id type key prompt; do
    if [[ $type == agent ]]; then
        [[ -n $prompt ]] || die 2 "$id has no quoted prompt in its question; scripts/eval/agent-tasks.sh runs it"
        [[ -z $agent_id ]] || die 2 "one agent row for each call; $agent_id and $id"
        agent_id="$id" agent_key="$key" agent_prompt="$prompt"
    elif [[ $key == *'(holdout)'* ]]; then
        found=""
        for f in ${holdout_files[@]+"${holdout_files[@]}"}; do
            line="$(awk -v id="## $id" '$0 == id { getline; print; exit }' "$f")"
            if [[ -n $line ]]; then found="$line"; break; fi
        done
        [[ -n $found ]] || die 2 "$id is a holdout with no key; give a --holdout-keys file that has \"## $id\""
        doc_ids+=("$id") doc_keys+=("$found")
    else
        doc_ids+=("$id") doc_keys+=("$key")
    fi
done <<<"$table"

# A tag that labels.tsv or scores.tsv holds counts its answers twice, and an answer file of an
# earlier call must not pass for a new one.
used_tag() { # <eval folder>
    [[ -f $1/labels.tsv ]] && awk -F'\t' -v t="$tag" '$2 == t { f = 1 } END { exit !f }' "$1/labels.tsv" && return 0
    [[ -f $1/scores.tsv ]] && awk -F'\t' -v t="$tag" '$1 == t { f = 1 } END { exit !f }' "$1/scores.tsv" && return 0
    return 1
}
fresh() { # <eval folder>: refuse a used tag and an answer folder that holds a file
    ! used_tag "$1" || die 2 "$1 already holds tag $tag; use a new tag"
    [[ ! -d $1/answer-$tag || -z "$(ls -A "$1/answer-$tag")" ]] || die 2 "$1/answer-$tag holds files; use a new tag"
}
[[ ${#doc_ids[@]} -eq 0 ]] || fresh "$eval_dir"
[[ -z $agent_id ]] || fresh "$eval_dir/agent"

# The docs copies. A copy is keyed to its commit by the stamp beside the build log.
mkdir -p "$eval_dir/logs"
build() { # <set> <hash>
    local s="$1" hash="$2" d="$eval_dir/docs-$1" log="$eval_dir/logs/build-$1.log" stamp="$eval_dir/logs/build-$1.commit"
    if [[ -d $d && -n "$(ls -A "$d")" ]]; then
        [[ -f $stamp && "$(cat "$stamp")" == "$hash" && "$(tail -n 1 "$log" 2>/dev/null)" == 'byte check end' ]] && return 0
        die 2 "$d is not a finished copy of $hash (stamp: $(cat "$stamp" 2>/dev/null || echo none)); give a new eval folder"
    fi
    (cd "$repo" && "$here/build-copy.sh" "$hash" "$d" "$log") || die 2 "the build of $d failed"
    [[ "$(tail -n 1 "$log")" == 'byte check end' ]] || die 2 "the build log of $d does not end with the byte check"
    printf '%s\n' "$hash" >"$stamp"
}
[[ ${#doc_ids[@]} -eq 0 ]] || build a "$hash_a"
build b "$hash_b"

# Sessions: start_session runs one command in the background; await_sessions waits for all of them.
S_NAME=() S_PID=() S_PRE=() S_EXPECT=()
work="" agent_work=()
stop_sessions() {
    local pid
    for pid in ${S_PID[@]+"${S_PID[@]}"}; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    wait
}
cleanup() {
    local d
    [[ -z $work ]] || rm -rf "$work"
    for d in ${agent_work[@]+"${agent_work[@]}"}; do rm -rf "$d"; done
}
trap 'stop_sessions; exit 130' INT
trap 'stop_sessions; exit 143' TERM
trap cleanup EXIT

start_session() { # <name> <expected file> <folder> <log prefix> <command> [args...]
    local name="$1" expect="$2" folder="$3" pre="$4"
    shift 4
    rm -f "$pre.status"
    ( cd "$folder" && "$@" </dev/null >"$pre.out" 2>"$pre.err"; echo $? >"$pre.status" ) &
    S_NAME+=("$name") S_PID+=("$!") S_PRE+=("$pre") S_EXPECT+=("$expect")
}
await_sessions() {
    local n=${#S_PID[@]} i st left failed=0 finished=()
    left=$n
    for ((i = 0; i < n; i++)); do finished[i]=0; done
    while ((left > 0)); do
        for ((i = 0; i < n; i++)); do
            ((finished[i])) && continue
            [[ -s ${S_PRE[i]}.status ]] || continue
            finished[i]=1
            left=$((left - 1))
            st="$(cat "${S_PRE[i]}.status")"
            if [[ $st != 0 ]]; then
                echo "run.sh: session ${S_NAME[i]} failed: exit $st (${S_PRE[i]}.out)" >&2
                failed=1
            elif [[ ! -s ${S_EXPECT[i]} ]]; then
                echo "run.sh: session ${S_NAME[i]} exited 0 but wrote no ${S_EXPECT[i]##*/}" >&2
                failed=1
            fi
        done
        ((failed)) && break
        ((left > 0)) && sleep 0.2
    done
    ((failed)) && stop_sessions
    wait
    S_NAME=() S_PID=() S_PRE=() S_EXPECT=()
    ((failed == 0)) || exit 3
}

common=(--setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' --permission-mode acceptEdits --no-session-persistence)
work="$(mktemp -d "${TMPDIR:-/tmp}/dirigible-eval-XXXXXX")"

grader_prompt() { # <packet> <result>
    cat <<EOF
You are a blind grader of a docs eval. Read only this file: $1

For each scenario, each answer (a neutral label), and each key point, decide PASS or FAIL. A key point passes when the quotes (Q lines) of that answer state it, in the same or other words. A quote that states only part of a key point fails that key point. Do not use your own knowledge to fill a gap. Judge each answer alone.

Write one JSON file to $2, with the Write tool, and nothing else. Its shape is a list with one object for each label and key point:

[{"label": "<label>", "key": "(a)", "result": "PASS", "reason": "<one sentence: the quote that holds it, or what is missing>"}]

Then reply with one line: the count of objects.
EOF
}

# grade <eval folder> <packet count> <set:run:kept.json>...: packets, blind graders, scores.
grade() {
    local ev="$1" count="$2" n results=()
    shift 2
    python3 -I "$here/grade.py" packets "$ev" "$tag" 1 "$count" "$@" 2>"$eval_dir/logs/$tag-packets.log" \
        || die 3 "grade.py packets failed (see $eval_dir/logs/$tag-packets.log)"
    for ((n = 1; n <= count; n++)); do
        results+=("$ev/grade/result-$tag-$n.json")
        start_session "grader-$tag-$n" "$ev/grade/result-$tag-$n.json" "$work" "$eval_dir/logs/$tag-grader-$(basename "$ev")-$n" \
            claude -p "$(grader_prompt "$ev/grade/packet-$tag-$n.md" "$ev/grade/result-$tag-$n.json")" --model "$GRADER_MODEL" \
            "${common[@]}" --safe-mode --tools Read,Write --allowedTools "Read(/$ev/grade/packet-$tag-$n.md)" "Edit(/$ev/grade/result-$tag-$n.json)"
    done
    await_sessions
    python3 -I "$here/grade.py" score "$ev" "$tag" "${results[@]}" >"$eval_dir/logs/$tag-score-$(basename "$ev").log" \
        || die 3 "grade.py score failed"
}

verdict_code=0
if [[ ${#doc_ids[@]} -gt 0 ]]; then
    ans="$eval_dir/answer-$tag"
    mkdir -p "$ans" "$eval_dir/grade"
    ids_csv="$(IFS=,; echo "${doc_ids[*]}")"
    python3 -I "$here/questions.py" "$evals_md" "$ans" "$ids_csv" "$RUNS" >"$eval_dir/logs/$tag-questions.log" \
        || die 2 "questions.py failed (see $eval_dir/logs/$tag-questions.log)"
    for s in a b; do
        for ((r = 1; r <= RUNS; r++)); do
            start_session "prompt-$s-$r" "$ans/run-$s-$r.json" "$work" "$eval_dir/logs/$tag-answer-$s-$r" \
                claude -p "$(cat "$ans/prompt-$s-$r.md")" --model "$ANSWER_MODEL" "${common[@]}" --safe-mode --tools Read,Write \
                --allowedTools "Read(/$eval_dir/docs-$s/**)" "Read(/$ans/questions-$s-$r.txt)" "Edit(/$ans/run-$s-$r.json)"
        done
    done
    await_sessions
    # keys.md comes after the answer sessions: no answer session can read a key.
    : >"$eval_dir/keys.md"
    for i in "${!doc_ids[@]}"; do printf '## %s\n%s\n\n' "${doc_ids[i]}" "${doc_keys[i]}" >>"$eval_dir/keys.md"; done
    specs=()
    for s in a b; do
        for ((r = 1; r <= RUNS; r++)); do
            python3 -I "$here/quote-check.py" "$ans/run-$s-$r.json" "$eval_dir/docs-$s" --out "$ans/kept-$s-$r.json" \
                >"$eval_dir/logs/$tag-qc-$s-$r.log" 2>&1 \
                || die 3 "the quote check of run-$s-$r.json failed (see $eval_dir/logs/$tag-qc-$s-$r.log)"
            specs+=("$s:$r:$ans/kept-$s-$r.json")
        done
    done
    count=${#doc_ids[@]}
    ((count <= 4)) || count=4
    grade "$eval_dir" "$count" "${specs[@]}"
    python3 -I "$here/grade.py" verdict "$eval_dir" a b
    verdict_code=$?
fi

if [[ -n $agent_id ]]; then
    ag="$eval_dir/agent"
    # --safe-mode would drop the skills and the CLAUDE.md of the docs copy: only the global file goes.
    agent_settings="$(python3 -I -c 'import json, os, sys
print(json.dumps({"claudeMdExcludes": [os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "CLAUDE.md")]}))')"
    ans="$ag/answer-$tag"
    mkdir -p "$ans" "$ag/grade"
    # A key point is a predicate on one answer: the run counts of the row go to the caller.
    agent_key="$(sed -E 's/In at least [0-9]+ of [0-9]+ runs, the /The /; s/In each run, the /The /' <<<"$agent_key")"
    ! grep -qE 'of [0-9]+ runs|In each run' <<<"$agent_key" || die 2 "the key points of $agent_id hold a run count: $agent_key"
    for ((r = 1; r <= RUNS; r++)); do
        aw="$(mktemp -d /private/tmp/dirigible-eval-agent-XXXXXX)"
        agent_work+=("$aw")
        cp -R "$eval_dir/docs-b/." "$aw/"
        mkdir "$aw/tmp"
        start_session "$agent_id-$r" "$eval_dir/logs/$tag-agent-$r.out" "$aw" "$eval_dir/logs/$tag-agent-$r" \
            "$repo/scripts/probe.sh" --no-audio "$aw" env CLAUDE_CODE_TMPDIR="$aw/tmp" TMPDIR="$aw/tmp" \
            claude -p "$agent_prompt" --model "$ANSWER_MODEL" "${common[@]}" --settings "$agent_settings" --tools Skill,Read --allowedTools Skill Read --output-format json
    done
    await_sessions
    printf '## %s\n%s\n' "$agent_id" "$agent_key" >"$ag/keys.md"
    specs=()
    for ((r = 1; r <= RUNS; r++)); do
        cp "$eval_dir/logs/$tag-agent-$r.out" "$ans/run-$r.json"
        python3 -I -c '
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
if obj.get("is_error") or not str(obj.get("result", "")).strip():
    sys.exit("is_error or an empty result")
json.dump({"kept": {sys.argv[3]: [{"quote": " ".join(str(obj["result"]).split())}]}}, open(sys.argv[2], "w", encoding="utf-8"))
' "$ans/run-$r.json" "$ans/kept-$r.json" "$agent_id" || die 3 "session $agent_id-$r returned an error or no result (see $ans/run-$r.json)"
        specs+=("b:$r:$ans/kept-$r.json")
    done
    grade "$ag" 1 "${specs[@]}"
    cat "$eval_dir/logs/$tag-score-agent.log"
fi
exit "$verdict_code"
