#!/bin/bash
# Check that workflow-words.sh counts the workflow docs, the always-on words, and the skills and
# agents in the work tree and at a commit. Each case uses a temporary repo. Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/workflow-words.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

g() { git -C "$tmp/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
w() { (cd "$tmp/r" && "$script" "$@" 2>&1); }

# is <name> <want> <mode> [args]: the output is the number <want>.
is() {
  local name="$1" want="$2" got
  shift 2
  got="$(w "$@")" || { fail "$name: exit $?: $got"; return; }
  [[ "$got" == "$want" ]] || fail "$name: want $want, got $got"
}

# put <path> <text>: write a file of the repo.
put() { mkdir -p "$(dirname "$tmp/r/$1")"; printf '%s\n' "$2" > "$tmp/r/$1"; }
# skill <name> <description lines>: a SKILL.md with a frontmatter.
skill() { local n="$1"; shift; put ".claude/skills/$n/SKILL.md" "$(printf -- '---\nname: %s\n' "$n"; printf '%s\n' "$@"; printf -- '---\nbody words here\n')"; }

new_repo() {
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r"
  g init -q -b main
  put AGENTS.md 'a b c'
  put CLAUDE.md '@AGENTS.md'
  put CODING_STANDARDS.md 'c1 c2'
  put .claude/agents/x.md "$(printf -- '---\nname: x\ndescription: one two\n---\nbody')"
  skill s 'description: three four five'
  put .claude/skills/s/references/r.md 'r1 r2 r3 r4'
  skill p 'description: pp'
  put .claude/skills/THIRD_PARTY.md 'Pinned skills: `p`.'
  g add -A
  g commit -q -m base
}

new_repo
is 'always-on words' 10 always-on
is 'count of skills and agents' 3 count
# AGENTS.md 3, CODING_STANDARDS.md 2, agent x 8, skill s 11, r.md 4; skill p is pinned; THIRD_PARTY.md is no doc.
is 'sum without the pinned folder' 28 sum
[[ "$(w list)" == $'.claude/agents/x.md\n.claude/skills/p/SKILL.md\n.claude/skills/s/SKILL.md\n.claude/skills/s/references/r.md\nAGENTS.md\nCODING_STANDARDS.md' ]] || fail "list: $(w list)"

# A commit is read with --rev; the work tree is read without it. Both read the files that git
# tracks: an untracked doc counts in neither, so a comparison reads one file set.
put AGENTS.md 'a b c d e'
put .claude/agents/y.md "$(printf -- '---\nname: y\ndescription: six\n---\n')"
is 'work tree reads a longer AGENTS.md and not an untracked agent' 12 always-on
is 'work tree count has no untracked agent' 3 count
[[ "$(w list)" != *y.md* ]] || fail "list shows an untracked agent: $(w list)"
is 'work tree sum has no untracked agent' 30 sum
g add -A
is 'work tree sees a staged agent' 13 always-on
is 'work tree count of a staged agent' 4 count
is '--rev reads the commit' 10 always-on --rev HEAD
is '--rev count' 3 count --rev HEAD
is '--root names the repo' 13 always-on --root "$tmp/r"
rm -rf "$tmp/n"; mkdir -p "$tmp/n/.claude/agents"
printf -- '---\nname: z\ndescription: one two\n---\n' > "$tmp/n/.claude/agents/z.md"
out="$("$script" always-on --root "$tmp/n" 2>&1)" && [[ "$out" == 2 ]] || fail "a folder with no git reads the files on disk: $out"

# A folded description counts its words, not its indicator.
for ind in '>' '|' '>-' '|-'; do
  new_repo
  skill s "description: $ind" '  three' '  four five'
  is "a folded description ($ind)" 10 always-on
done
new_repo
skill s 'description: three four' '  five' 'model: x'
is 'a description before another key' 10 always-on

# An @ line imports a file once, and a chain imports its files.
new_repo
put CLAUDE.md "$(printf '@AGENTS.md\n@docs/x.md\n@missing.md')"
put docs/x.md 'i1 i2 i3 @not-an-import'
put docs/y.md 'j1 j2'
is 'an imported file and a missing import' 16 always-on
put docs/x.md "$(printf 'i1 i2 i3\n@y.md')"
is 'an import of an import' 18 always-on
put docs/x.md "$(printf 'i1 i2 i3\n@../AGENTS.md')"
is 'an import cycle counts a file once' 16 always-on
put AGENTS.md "$(printf 'a b c\n@docs/x.md')"
put CLAUDE.md '@AGENTS.md'
put docs/x.md 'i1 i2 i3'
is 'AGENTS.md imports a file' 14 always-on

# Claude Code also loads .claude/CLAUDE.md and each .claude/rules file with no paths: frontmatter at the start.
new_repo
put .claude/CLAUDE.md 'k1 k2'
g add -A
is '.claude/CLAUDE.md is a start file' 12 always-on
put .claude/rules/a.md 'r1 r2 r3'
put .claude/rules/sub/b.md 'b1'
g add -A
is 'a rules file and a nested rules file with no paths: are start files' 16 always-on
put .claude/rules/c.md "$(printf -- '---\npaths:\n  - "src/**"\n---\nc1 c2 c3 c4')"
g add -A
is 'a rules file with paths: is no start file' 16 always-on
put .claude/rules/d.md "$(printf -- '---\ndescription: x\n---\nd1 d2')"
g add -A
is 'a rules file with a frontmatter and no paths: is a start file' 22 always-on
put .claude/rules/a.md "$(printf 'r1 r2 r3\n@../../docs/x.md')"
put docs/x.md 'i1 i2'
g add -A
is 'a rules file imports a file' 25 always-on
g add -A
[[ "$(w start-files)" == $'AGENTS.md\nCLAUDE.md\n.claude/CLAUDE.md\n.claude/rules/a.md\n.claude/rules/d.md\n.claude/rules/sub/b.md\ndocs/x.md' ]] || fail "start-files: $(w start-files)"

# A repo with no workflow file gives 0 in each mode and does not stop.
rm -rf "$tmp/r"; mkdir -p "$tmp/r"; g init -q -b main; put README.md 'x'; g add -A; g commit -q -m base
for m in always-on count sum; do
  is "no workflow file, $m" 0 "$m"
  is "no workflow file, $m at a commit" 0 "$m" --rev HEAD
done
is 'no workflow file, list' '' list
rm -rf "$tmp/n"; mkdir -p "$tmp/n"
out="$("$script" always-on --root "$tmp/n" 2>&1)" && [[ "$out" == 0 ]] || fail "a folder with no git: $out"

# A bad mode, a bad argument, and a bad commit exit 2.
for args in 'nope' '' 'sum --what' 'sum --rev does-not-exist'; do
  out="$(cd "$tmp/r" && "$script" $args 2>&1)"
  [[ $? -eq 2 ]] || fail "bad arguments '$args': not exit 2: $out"
  [[ "$out" == workflow-words:* ]] || fail "bad arguments '$args': no message: $out"
done

[[ $failures -eq 0 ]] && echo "workflow-words: all cases pass" || exit 1
