#!/usr/bin/env python3
"""Quote check of one eval answer file (docs/workflow/evals.md).

Usage: quote-check.py <answer.json> <set folder> [<alias> ...] [--out <kept.json>]

The set folder is the copy of one doc set (scripts/eval/build-copy.sh). An alias is another
path that names the same folder (a symlink that the answerer saw). The script removes
the set prefix from each path.

Answer file (JSON):
  {"chain":   [{"path": "...", "from": "..." | null, "pointer": "..." | null}, ...],
   "answers": [{"id": "E1", "steps": [{"quote": "...", "path": "..."}, ...]}, ...]}

Rules:
- The two start files need no pointer: AGENTS.md and .claude/skills/deliver/SKILL.md.
- Each other chain file needs a "from" file that comes earlier in the chain. The pointer
  must be a substring of the "from" file, and it must name the path of the file. A pointer
  names a path when it holds one of these:
    the full path;
    the path relative to the skill folder of the "from" file (references/x.md, scripts/x.py);
    "**<name>** skill" for .claude/skills/<name>/SKILL.md;
    ".claude/agents/" and "<name>" for .claude/agents/<name>.md.
- A quote survives when its path is a chain file that passed, and the quote is a substring
  of that file. Both sides get each run of white space changed to one space. Nothing else
  is changed.
- A chain path outside the set folder makes the run void (exit 3).
Exit: 0 when the check ran (drops are in the output), 2 on bad input, 3 on a void run.
"""
import json
import os
import re
import sys

START = ["AGENTS.md", ".claude/skills/deliver/SKILL.md"]


def norm_ws(text):
    return re.sub(r"\s+", " ", text).strip()


def rel_path(p, roots):
    if p is None:
        return None
    p = p.strip()
    for root in roots:
        for r in (root, os.path.abspath(root), os.path.realpath(root)):
            r = r.rstrip("/") + "/"
            if p.startswith(r):
                return p[len(r):]
    if p.startswith("./"):
        p = p[2:]
    return p


def outside(p):
    return p.startswith("/") or p.startswith("~") or ".." in p.split("/")


def names_path(pointer, from_path, target):
    if target in pointer:
        return True
    parts = from_path.split("/")
    if len(parts) > 3 and parts[0] == ".claude" and parts[1] == "skills":
        skill_root = "/".join(parts[:3]) + "/"
        if target.startswith(skill_root) and target[len(skill_root):] in pointer:
            return True
    m = re.fullmatch(r"\.claude/skills/([^/]+)/SKILL\.md", target)
    if m and re.search(r"\*\*" + re.escape(m.group(1)) + r"\*\*\s+skill", pointer):
        return True
    m = re.fullmatch(r"\.claude/agents/([^/]+)\.md", target)
    if m and ".claude/agents/" in pointer and m.group(1) in pointer:
        return True
    return False


def check(answer, roots):
    root = roots[0]
    texts = {}

    def text_of(p):
        if p not in texts:
            full = os.path.join(root, p)
            texts[p] = norm_ws(open(full, encoding="utf-8").read()) if os.path.isfile(full) else None
        return texts[p]

    report = {"void": [], "chain": [], "dropped": [], "kept": {}}
    good = set()
    seen = []
    for entry in answer.get("chain", []):
        p = rel_path(entry.get("path"), roots)
        src = rel_path(entry.get("from"), roots)
        ptr = entry.get("pointer") or ""
        if outside(p) or (src and outside(src)):
            report["void"].append(f"path outside the set folder: {entry.get('path')} (from {entry.get('from')})")
            seen.append(p)
            continue
        if p in START:
            reason = None
        elif text_of(p) is None:
            reason = "file does not exist in the set"
        elif not src or src not in seen:
            reason = "no earlier file of the chain points to it"
        elif src not in good:
            reason = "the pointing file itself failed the chain check"
        elif not ptr or norm_ws(ptr) not in (text_of(src) or ""):
            reason = "the pointer is not a substring of the pointing file"
        elif not names_path(norm_ws(ptr), src, p):
            reason = "the pointer does not name the path"
        else:
            reason = None
        if reason is None and text_of(p) is not None:
            good.add(p)
        report["chain"].append({"path": p, "ok": reason is None, "reason": reason})
        seen.append(p)
    for ans in answer.get("answers", []):
        kept = []
        for step in ans.get("steps", []):
            p = rel_path(step.get("path"), roots)
            q = norm_ws(step.get("quote") or "")
            if not q:
                reason = "empty quote"
            elif p not in good:
                reason = "the path is not a chain file that passed"
            elif q not in text_of(p):
                reason = "the quote is not a substring of the file"
            else:
                kept.append({"path": p, "quote": step["quote"]})
                continue
            report["dropped"].append({"id": ans.get("id"), "path": p, "quote": q[:120], "reason": reason})
        report["kept"][ans.get("id")] = kept
    return report


def main(argv):
    out = None
    if "--out" in argv:
        i = argv.index("--out")
        out = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        answer = json.load(open(argv[0], encoding="utf-8"))
    except (OSError, ValueError) as err:
        print(f"bad answer file: {err}", file=sys.stderr)
        return 2
    report = check(answer, argv[1:])
    if out:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1)
    bad_chain = [c for c in report["chain"] if not c["ok"]]
    n_kept = sum(len(v) for v in report["kept"].values())
    print(f"chain: {len(report['chain'])} files, {len(bad_chain)} failed; quotes kept {n_kept}, dropped {len(report['dropped'])}")
    for c in bad_chain:
        print(f"CHAIN FAIL {c['path']}: {c['reason']}")
    for d in report["dropped"]:
        print(f"DROP {d['id']} {d['path']}: {d['reason']}: {d['quote']}")
    for v in report["void"]:
        print(f"VOID {v}")
    return 3 if report["void"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
