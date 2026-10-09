#!/usr/bin/env python3
"""Blind grading packets and scores for the eval (docs/workflow/evals.md).

<eval> is the eval folder of the run: it holds keys.md, labels.tsv, scores.tsv, and grade/.

packets: grade.py packets <eval> <tag> <seed> <packets> <set>:<run>:<kept.json> ...
  Reads keys.md and each quote-check report (--out of quote-check.py). The asked
  scenarios are the union of the kept maps of the reports. stderr names each kept ID
  that keys.md does not have (it is dropped) and each scenario of keys.md that no
  report holds. Gives each answer (set, run, asked scenario) a random neutral label (a
  report with no answer to it gets one with no quotes), shuffles the answers of each
  scenario, splits the scenarios into <packets> files <eval>/grade/packet-<tag>-<n>.md, and
  appends the label map to labels.tsv (the grader never reads labels.tsv).
  A tag that labels.tsv already holds exits 2.
score:   grade.py score <eval> <tag> <result.json> ...
  Each result file is a JSON list of {"label", "key", "result"}. A scenario passes in a
  run when each of its key points is PASS. A key point with no result is FAIL. Appends
  rows to scores.tsv: tag, scenario, type, set, run, result, missing. A tag that
  scores.tsv already holds exits 2. The type is the Type
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


def refuse_used(tag, name, column):
    """Exit 2 when the tag is in the column of the file: a second append counts twice."""
    path = os.path.join(EVAL, name)
    if os.path.exists(path) and any(line.split("\t")[column] == tag for line in open(path, encoding="utf-8")):
        print(f"grade.py: {name} already holds tag {tag}; use a new tag", file=sys.stderr)
        sys.exit(2)


def keys():
    text = open(os.path.join(EVAL, "keys.md"), encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^## ([EH]\d+)\n(.+)$", text, re.M):
        parts = re.split(r"(?:^|\s)\(([a-z])\) ", m.group(2))
        out[m.group(1)] = {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}
    return out


def packets(tag, seed, n, specs):
    refuse_used(tag, "labels.tsv", 1)
    rnd = random.Random(seed)
    k = keys()
    reports = []
    for spec in specs:
        set_name, run, path = spec.split(":", 2)
        reports.append((set_name, run, json.load(open(path, encoding="utf-8"))["kept"]))
    # The asked scenarios: the union of the kept maps, in the order of keys.md.
    held = set().union(*(kept for _, _, kept in reports))
    for sid in sorted(held - set(k)):
        print(f"grade.py: a report holds {sid}, which keys.md does not have; it is dropped", file=sys.stderr)
    for sid in [s for s in k if s not in held]:
        print(f"grade.py: no report of tag {tag} holds {sid} of keys.md", file=sys.stderr)
    scen = [s for s in k if s in held]
    answers = {sid: [(set_name, run, kept.get(sid, [])) for set_name, run, kept in reports] for sid in scen}
    used = set()
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
    refuse_used(tag, "scores.tsv", 0)
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
        rows.append((tag, sid, typ[sid], set_name, run, "FAIL" if missing else "PASS", ",".join(missing)))
    order = list(k)
    rows.sort(key=lambda r: (order.index(r[1]), r[3], r[4]))
    path = os.path.join(EVAL, "scores.tsv")
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as f:
        if new:
            f.write("tag\tscenario\ttype\tset\trun\tresult\tmissing\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    for r in rows:
        print("\t".join(r))


if __name__ == "__main__":
    command, EVAL = sys.argv[1:3] if len(sys.argv) > 3 else ("", "")
    if command == "packets":
        packets(sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6:])
    elif command == "score":
        score(sys.argv[3], sys.argv[4:])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
