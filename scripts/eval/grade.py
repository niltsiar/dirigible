#!/usr/bin/env python3
"""Blind grading packets and scores for the eval (docs/workflow/evals.md).

<eval> is the eval folder of the run: it holds keys.md, labels.tsv, scores.tsv, and grade/.

packets: grade.py packets <eval> <tag> <seed> <packets> <set>:<run>:<kept.json> ...
  Reads keys.md and each quote-check report (--out of quote-check.py). Gives each
  answer (set, run, scenario) a random neutral label, shuffles the answers of each
  scenario, splits the scenarios into <packets> files <eval>/grade/packet-<tag>-<n>.md, and
  appends the label map to labels.tsv (the grader never reads labels.tsv).
score:   grade.py score <eval> <tag> <result.json> ...
  Each result file is a JSON list of {"label", "key", "result"}. A scenario passes in a
  run when each of its key points is PASS. A key point with no result is FAIL. Appends
  rows to scores.tsv: scenario, type, set, run, result, missing. The type is the Type
  cell of the Scenarios table of docs/workflow/evals.md in the tree of this script.
"""
import json
import os
import random
import re
import string
import sys

EVALS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "workflow", "evals.md")
EVAL = ""


def types():
    """The Type cell of each row of the Scenarios table."""
    out, inside = {}, False
    for line in open(EVALS, encoding="utf-8"):
        if line.startswith("## "):
            inside = line.startswith("## Scenarios")
        elif inside and re.match(r"\| [EH][0-9]+ \|", line):
            cells = line.split("|")
            out[cells[1].strip()] = cells[2].strip()
    return out


def keys():
    text = open(os.path.join(EVAL, "keys.md"), encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^## ([EH]\d+)\n(.+)$", text, re.M):
        parts = re.split(r"(?:^|\s)\(([a-z])\) ", m.group(2))
        out[m.group(1)] = {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}
    return out


def packets(tag, seed, n, specs):
    rnd = random.Random(seed)
    k = keys()
    answers = {}
    for spec in specs:
        set_name, run, path = spec.split(":", 2)
        report = json.load(open(path, encoding="utf-8"))
        for sid in k:
            answers.setdefault(sid, []).append((set_name, run, report["kept"].get(sid, [])))
    used = set()
    scen = list(k)
    rnd.shuffle(scen)
    os.makedirs(os.path.join(EVAL, "grade"), exist_ok=True)
    with open(os.path.join(EVAL, "labels.tsv"), "a", encoding="utf-8") as lab:
        for p in range(n):
            chunk = scen[p::n]
            lines = [f"# Grading packet {tag}-{p + 1}", ""]
            for sid in chunk:
                lines += [f"## Scenario {sid}", "", "Key points:"]
                lines += [f"- ({letter}) {text}" for letter, text in k[sid].items()]
                lines.append("")
                items = answers[sid][:]
                rnd.shuffle(items)
                for set_name, run, kept in items:
                    while True:
                        label = "".join(rnd.choices(string.ascii_uppercase + string.digits, k=5))
                        if label not in used:
                            used.add(label)
                            break
                    lab.write(f"{label}\t{tag}\t{p + 1}\t{sid}\t{set_name}\t{run}\n")
                    lines.append(f"### Answer {label}")
                    lines += [f"- Q{i + 1}: {q['quote']}" for i, q in enumerate(kept)] or ["- (no quotes)"]
                    lines.append("")
            with open(os.path.join(EVAL, "grade", f"packet-{tag}-{p + 1}.md"), "w", encoding="utf-8") as f:
                f.write("\n".join(lines))


def score(tag, results):
    k = keys()
    typ = types()
    got = {}
    for path in results:
        for row in json.load(open(path, encoding="utf-8")):
            got[(row["label"], row["key"].strip("() "))] = row["result"].strip().upper()
    rows = []
    for line in open(os.path.join(EVAL, "labels.tsv"), encoding="utf-8"):
        label, t, _, sid, set_name, run = line.rstrip("\n").split("\t")
        if t != tag:
            continue
        missing = [x for x in k[sid] if got.get((label, x)) != "PASS"]
        if sid not in typ:
            sys.exit(f"grade.py: {sid} has no row in {EVALS}")
        rows.append((sid, typ[sid], set_name, run, "FAIL" if missing else "PASS", ",".join(missing)))
    order = list(k)
    rows.sort(key=lambda r: (order.index(r[0]), r[2], r[3]))
    path = os.path.join(EVAL, "scores.tsv")
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as f:
        if new:
            f.write("scenario\ttype\tset\trun\tresult\tmissing\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    for r in rows:
        print("\t".join(r))


if __name__ == "__main__":
    if len(sys.argv) > 3:
        EVAL = sys.argv[2]
    if EVAL and sys.argv[1] == "packets":
        packets(sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6:])
    elif EVAL and sys.argv[1] == "score":
        score(sys.argv[3], sys.argv[4:])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
