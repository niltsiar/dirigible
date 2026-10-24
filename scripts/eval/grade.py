#!/usr/bin/env python3
"""Blind grading packets and scores for the eval (docs/workflow/evals.md).

<eval> is the eval folder of the run: it holds keys.md, labels.tsv, scores.tsv, and grade/.

packets: grade.py packets <eval> <tag> <seed> <packets> <set>:<run>:<kept.json> ...
  Reads keys.md and each quote-check report (--out of quote-check.py). The asked
  scenarios are the union of the kept maps of the reports. stderr names each kept ID
  that keys.md does not have (it is dropped) and each scenario of keys.md that no
  report holds. Gives each answer (set, run, asked scenario) a random neutral label (a
  report with no answer to it gets one with no quotes), shuffles the answers of each
  scenario, splits the scenarios into <packets> files <eval>/grade/packet-<tag>-<n>.md (each
  scenario has its Question cell of the Scenarios table, then its key points), and
  appends the label map to labels.tsv (the grader never reads labels.tsv).
  A tag that labels.tsv already holds exits 2.
score:   grade.py score <eval> <tag> <result.json> ...
  Each result file is a JSON list of {"label", "key", "result"}. A scenario passes in a
  run when each of its key points is PASS. A key point with no result is FAIL, and so is
  one with the result UNASKED. Appends
  rows to scores.tsv: tag, scenario, type, set, run, result, missing. A tag that
  scores.tsv already holds exits 2. The type is the Type
  cell of the Scenarios table of docs/workflow/evals.md in the tree of this script.
  An object {"scenario", "key", "result": "UNASKED", "reason"} says that the question of the
  scenario does not ask a clause of that key point. It adds a row (tag, scenario, key,
  reason) to unasked.tsv. It changes no row of scores.tsv.
verdict: grade.py verdict <eval> <old set> <new set>
  Reads scores.tsv of all tags and counts passes and runs per scenario and set. A set
  with no row exits 2. A tag whose two sets hold different scenarios exits 2 (so each
  policy scenario has a new-set run); other tags pool. Prints a line per
  clause of the pass rule of evals.md: void <H> (a holdout with no pass in both sets,
  in no other line), the retention sum (it fails only when old minus new is over the bound
  2 x sqrt(sum of k x p x (1 - p)) of the live retention scenarios, with k the runs of both
  sets and p the pooled pass rate), below <id> (not due under 6 runs in a set),
  policy <id>, and out of reach <id> (<key>) after the lines of a scenario (a key point in the
  missing column of each row of both sets: no answer holds it; it changes no exit status).
  A fail of holdouts only (a below fail of an H, or a sum fail that the sum
  with no H does not have) prints holdout fail <H>: no changed text, once for each H, and does
  not fail the verdict, and the same lines go to <eval>/holdout-fails.txt (empty for none; each
  verdict replaces it). The last line is verdict: PASS (exit 0) or verdict: FAIL (exit 1).
  unasked.tsv (from score) makes a second count. A row passes in it when its missing keys are
  all unasked keys of its tag and scenario. unasked <ID> (<key>) lists the keys after the lines
  of the scenario. A clause of the retention sum, below, or policy that fails on the first count
  and passes on the second prints unasked fail <ID>: fix the question or the key (retention
  for the sum), and does not fail the verdict. The second count holds for a tag and scenario
  only while more than half of its key points are asked. With half or more unasked, the base
  count holds and unasked majority <ID>: fix the question or the key prints once for the
  scenario. With no unasked.tsv, the output is the base output.
"""
import json
import math
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


def questions():
    """The Question cell of each row of the Scenarios table (the cell that questions.py reads)."""
    out, inside = {}, False
    for line in open(EVALS, encoding="utf-8"):
        if line.startswith("## "):
            inside = line.startswith("## Scenarios")
        elif inside and re.match(r"\| [EH][0-9]+ \|", line):
            cells = line.split("|")
            out[cells[1].strip()] = cells[4].strip()
    return out


def packets(tag, seed, n, specs):
    refuse_used(tag, "labels.tsv", 1)
    rnd = random.Random(seed)
    k = keys()
    asks = questions()
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
    for sid in scen:
        if sid not in asks:
            sys.exit(f"grade.py: {sid} has no row in {EVALS}")
    answers = {sid: [(set_name, run, kept.get(sid, [])) for set_name, run, kept in reports] for sid in scen}
    used = set()
    rnd.shuffle(scen)
    os.makedirs(os.path.join(EVAL, "grade"), exist_ok=True)
    with open(os.path.join(EVAL, "labels.tsv"), "a", encoding="utf-8") as lab:
        for p in range(n):
            chunk = scen[p::n]
            lines = [f"# Grading packet {tag}-{p + 1}", ""]
            for sid in chunk:
                lines += [f"## Scenario {sid}", "", f"Question: {asks[sid]}", "", "Key points:"]
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
    got, unasked = {}, {}
    for path in results:
        for row in json.load(open(path, encoding="utf-8")):
            if "scenario" in row and row["result"].strip().upper() == "UNASKED":
                unasked[(row["scenario"], row["key"].strip("() "))] = " ".join(row.get("reason", "").split())
            else:
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
    scenarios = {r[1] for r in rows}
    held = {(sid, key): reason for (sid, key), reason in sorted(unasked.items()) if sid in scenarios and key in k[sid]}
    for sid, key in sorted(set(unasked) - set(held)):
        print(f"grade.py: UNASKED for {sid} ({key}) is not a key point of tag {tag}; it is dropped", file=sys.stderr)
    if held:
        with open(os.path.join(EVAL, "unasked.tsv"), "a", encoding="utf-8") as f:
            f.writelines(f"{tag}\t{sid}\t({key})\t{reason}\n" for (sid, key), reason in held.items())


def unasked_keys():
    """(tag, scenario) -> the key letters that unasked.tsv holds."""
    path, out = os.path.join(EVAL, "unasked.tsv"), {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            tag, sid, key = line.split("\t")[:3]
            out.setdefault((tag, sid), set()).add(key.strip("() "))
    return out


def verdict(old, new):
    rows = [line.rstrip("\n").split("\t") for line in open(os.path.join(EVAL, "scores.tsv"), encoding="utf-8")][1:]
    # A set with no row (a typo, an empty file) leaves each clause empty, and the verdict would pass.
    for set_name in (old, new):
        if not any(r[3] == set_name for r in rows):
            print(f"grade.py: scores.tsv has no row of set {set_name}", file=sys.stderr)
            sys.exit(2)
    by_tag = {}
    for tag, sid, _, set_name, _, _, _ in rows:
        by_tag.setdefault(tag, {}).setdefault(set_name, set()).add(sid)
    for tag, sets in by_tag.items():
        if sets.get(old, set()) != sets.get(new, set()):
            print(f"grade.py: tag {tag} holds other scenarios in set {old} than in set {new}", file=sys.stderr)
            sys.exit(2)
    # The second count drops the unasked keys of a tag and scenario, only while more than half of
    # its key points are asked. The other tags and scenarios keep the base count.
    unasked = unasked_keys()
    total = {sid: len(points) for sid, points in keys().items()} if unasked else {}
    drops = {ts: u for ts, u in unasked.items() if ts[1] in total and 2 * len(u) < total[ts[1]]}
    passes, passes2, runs, typ, out_of_reach, listed, majority = {}, {}, {}, {}, {}, {}, set()
    for tag, sid, t, set_name, _, result, missing in rows:
        if set_name in (old, new):
            typ[sid] = t
            keys_missing = set(missing.split(",")) - {""}
            out_of_reach[sid] = out_of_reach[sid] & keys_missing if sid in out_of_reach else keys_missing
            runs[(sid, set_name)] = runs.get((sid, set_name), 0) + 1
            passes[(sid, set_name)] = passes.get((sid, set_name), 0) + (result == "PASS")
            second = result == "PASS" or bool(keys_missing) and keys_missing <= drops.get((tag, sid), set())
            passes2[(sid, set_name)] = passes2.get((sid, set_name), 0) + second
            listed.setdefault(sid, set()).update(unasked.get((tag, sid), set()))
            if (tag, sid) in unasked and (tag, sid) not in drops and sid in total:
                majority.add(sid)
    ok = True
    void = [s for s in typ if s.startswith("H") and not passes.get((s, old)) and not passes.get((s, new))]
    live = [s for s in typ if s not in void]
    for s in void:
        print(f"void {s}")
    def drop(ids, counts):
        """The old and new pass sums of the scenarios, and their bound 2 x sqrt(sum of k p (1 - p))."""
        spread = 0.0
        for s in ids:
            k = runs.get((s, old), 0) + runs.get((s, new), 0)
            p = (counts.get((s, old), 0) + counts.get((s, new), 0)) / k
            spread += k * p * (1 - p)
        return sum(counts.get((s, old), 0) for s in ids), sum(counts.get((s, new), 0) for s in ids), 2 * math.sqrt(spread)

    word = {True: "PASS", False: "FAIL"}
    fix = "fix the question or the key"
    # A fail of holdouts only does not fail the verdict: check-governance.sh stops the second in a row.
    held = []
    kept = [s for s in live if typ[s] == "retention"]
    old_sum, new_sum, bound = drop(kept, passes)
    print(f"retention: old {old_sum}, new {new_sum}, bound {bound:.1f}: {word[old_sum - new_sum <= bound]}")
    if old_sum - new_sum > bound:
        o2, n2, b2 = drop(kept, passes2)
        if o2 - n2 <= b2:
            print(f"unasked fail retention: {fix}")
        else:
            e_old, e_new, e_bound = drop([s for s in kept if not s.startswith("H")], passes)
            if e_old - e_new <= e_bound:
                held += [s for s in kept if s.startswith("H") and passes.get((s, new), 0) < passes.get((s, old), 0)]
            else:
                ok = False
    for s in live:
        ro, rn = runs.get((s, old), 0), runs.get((s, new), 0)
        def below(counts):
            return "not due" if min(ro, rn) < 6 else "PASS" if counts.get((s, new), 0) > counts.get((s, old), 0) - 2 else "FAIL"
        po, pn = passes.get((s, old), 0), passes.get((s, new), 0)
        result = below(passes)
        unasked_fail = result == "FAIL" and below(passes2) != "FAIL"
        if result == "FAIL" and s.startswith("H") and not unasked_fail:
            held.append(s)
        else:
            ok &= result != "FAIL" or unasked_fail
        print(f"below {s}: old {po}/{ro}, new {pn}/{rn}: {result}")
        if typ[s] == "policy":
            policy = 3 * pn >= 2 * rn
            if not policy and 3 * passes2.get((s, new), 0) >= 2 * rn:
                unasked_fail = True
            else:
                ok &= policy
            print(f"policy {s}: new {pn}/{rn}: {word[policy]}")
        for key in sorted(out_of_reach[s]):
            print(f"out of reach {s} ({key})")
        for key in sorted(listed.get(s, ())):
            print(f"unasked {s} ({key})")
        if s in majority:
            print(f"unasked majority {s}: {fix}")
        if unasked_fail:
            print(f"unasked fail {s}: {fix}")
    fails = [f"holdout fail {s}: no changed text" for s in dict.fromkeys(held)]
    for line in fails:
        print(line)
    # check-governance.sh reads this file: two holdout fails in a row stop the land with no hand step.
    with open(os.path.join(EVAL, "holdout-fails.txt"), "w", encoding="utf-8") as f:
        f.write("".join(line + "\n" for line in fails))
    print(f"verdict: {word[ok]}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    command, EVAL = sys.argv[1:3] if len(sys.argv) > 3 else ("", "")
    if command == "packets":
        packets(sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6:])
    elif command == "score":
        score(sys.argv[3], sys.argv[4:])
    elif command == "verdict" and len(sys.argv) == 5:
        verdict(sys.argv[3], sys.argv[4])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
