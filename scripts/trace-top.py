#!/usr/bin/env python3
"""Print the top leaf frames of a Time Profiler trace export.

Usage: scripts/trace-top.py [--under <text>] [--top <n>] <export.xml>
The input is the time-profile table of `xcrun xctrace export --xpath ...` (scripts/bench.sh
--trace writes it). Each row is one sample; its backtrace lists the leaf frame first. The export
gives each frame and each whole backtrace once with an id, and then by ref. A line is
"<leaf frame> <samples> <percent>%", sorted by samples, with the default top 20. With --under,
only the samples with a frame whose name holds <text> count (for example the @inline(never)
function that wraps the timed span of a bench). Exit 1 on a ref with no id, or when no sample is
under <text>. The script reads the XML with iterparse, so a large export does not load as one tree.
scripts/trace-top.test.sh tests it.
"""
import argparse
import collections
import sys
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--under")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("export")
    args = parser.parse_args()
    frames, backtraces = {}, {}
    counts, total = collections.Counter(), 0

    def resolve(table, ref):
        if ref not in table:
            sys.exit(f"trace-top: unresolved ref {ref}")
        return table[ref]

    for _, element in ET.iterparse(args.export):
        if element.tag != "row":
            continue
        backtrace = element.find("backtrace")
        if backtrace is not None:
            if "ref" in backtrace.attrib:
                names = resolve(backtraces, backtrace.get("ref"))
            else:
                names = []
                for frame in backtrace.findall("frame"):
                    if "ref" in frame.attrib:
                        names.append(resolve(frames, frame.get("ref")))
                    else:
                        frames[frame.get("id")] = frame.get("name") or frame.get("addr") or "?"
                        names.append(frames[frame.get("id")])
                backtraces[backtrace.get("id")] = names
            if names and (args.under is None or any(args.under in name for name in names)):
                counts[names[0]] += 1
                total += 1
        element.clear()
    if total == 0:
        sys.exit(f"trace-top: no sample under {args.under}" if args.under else "trace-top: no sample")
    for name, n in counts.most_common(args.top):
        print(f"{name} {n} {100 * n / total:.1f}%")


main()
