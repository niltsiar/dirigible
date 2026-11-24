#!/usr/bin/env python3
"""Check the docs for drift that a script can see.

Usage: python3 -I scripts/check-docs-drift.py [repo root]. scripts/check-docs.sh runs it once.
A miss is one line `check-docs: <file>:<line>: <what>` on stderr, and the exit status is 1.
A rule skips the input file that the tree lacks, so a small tree stays green.

Rules of this script (the one home of the rules):

menus      Each bold path `**A > B**` of README.md, docs/guide.md, docs/CONTRIBUTING.md, and
           CONTEXT.md is a menu path or a System Settings path. A path that starts with a menu
           title reads each later part against the `menu.*` strings of the English and Spanish
           tables only, so a button label cannot hide a lost ellipsis. AppKit adds `Undo`,
           `Redo`, and `Undo <action>` to the Edit menu, so those forms pass under Edit only.
           Any other path reads each part against any UI string or a name that macOS owns (the menu
           titles, Format, Settings..., the toolbar items, System Settings and the names of its panes,
           and Keychain Access with its certificate items). Decision 0010 (Checks) holds the
           ellipsis forms that this rule reads. A key in parentheses after a path, and each Key cell
           of the menu tables of the guide, is a key of Sources/DirigibleApp. The check is set
           membership: a shortcut that moves between two menu items leaves a stale row that passes.
menutables In the guide section `## Menu commands and keys`, no Key cell is `-`, and each `menu.*`
           string that has no parent key is bold in the section.
decstatus  A record with `- Status: proposed` names in its head (before the first `##`) an F-ID
           whose state in features.md is not done. The run that marks an F-ID done also accepts
           each proposed record whose head names only that open F-ID. Each Status cell of the
           docs map (docs/README.md) is the Status line of its record.
releases   A `## Release <n>:` section of releases.md with no `Status: closed` line fails only when
           a done State of features.md has a release m greater than n. The release of a done State
           is the first number after `done, Release `, after the cut of the `; Later:` part and of
           each note in parentheses (scripts/check-governance.sh does the same). A `(done` mark in
           releases.md fails: features.md holds the state.
deccites   A four-digit number 0001 up to the highest record number, outside a code span and not
           after `item`, `items`, or `backlog` in any letter case, names a decision record that exists. The sentence
           "The numbers ... are not used" of docs/README.md lists the gaps and is skipped.
private    README.md, docs/guide.md, docs/requirements/, docs/decisions/, and docs/research/ name
           no path into `.scratchpads/` (the bare folder name is fine). No file of docs/ names a
           backlog item by number (`item 1234`, `backlog 1234`, in any letter case): the backlog is a local file.
"""
import pathlib
import re
import sys

ELL = chr(0x2026)
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
misses = []


def miss(where, what):
    misses.append(f"check-docs: {where}: {what}")


def text(rel):
    p = root / rel
    return p.read_text(encoding="utf-8") if p.is_file() else None


def lines_of(rel):
    t = text(rel)
    return t.splitlines() if t is not None else []


def quotes(s):
    return s.replace(chr(0x201C), '"').replace(chr(0x201D), '"').replace(chr(0x2019), "'")


def strings(lang):
    raw = text(f"Support/Resources/{lang}.lproj/Localizable.strings") or ""
    out = {}
    for m in re.finditer(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";', raw, re.M):
        value = re.sub(r"\\U([0-9A-Fa-f]{4})", lambda u: chr(int(u.group(1), 16)), m.group(2))
        out[m.group(1)] = quotes(value)
    return out


def section(doc, heading_re):
    """The (number, line) pairs from the first heading that matches to the next heading of its level or higher."""
    out, level = [], None
    for i, line in enumerate(lines_of(doc), 1):
        m = re.match(r"^(#+) ", line)
        if level is None:
            if m and re.search(heading_re, line):
                level = len(m.group(1))
            continue
        if m and len(m.group(1)) <= level:
            break
        out.append((i, line))
    return out


def md_files(*folders):
    files = []
    for folder in folders:
        p = root / folder
        files += [p] if p.is_file() else sorted(p.rglob("*.md")) if p.is_dir() else []
    return files


def feature_states():
    """The state cell of each F-ID of features.md, or None when the file is missing."""
    rows = lines_of("docs/requirements/features.md")
    states = {}
    for line in rows:
        m = re.match(r"^\| (F\d+) \|", line)
        if m:
            cells = [c.strip() for c in line.split("|")]
            states[m.group(1)] = next((c for c in cells if c.startswith(("done", "Release", "Later", "Dropped"))), "")
    return states if rows else None


MENU_TITLES = {"Dirigible", "File", "Edit", "View", "Window", "Help", "Archivo", "Edición", "Ver", "Ventana", "Ayuda"}
# macOS owns these names: the menu titles, System Settings and its panes, the app menu items.
MACOS = MENU_TITLES | {"Format", "Settings...", "Customize Toolbar...", "Show Toolbar", "Hide Toolbar",
                       "System Settings", "Privacy & Security", "Screen & System Audio Recording", "Screen Recording",
                       "Microphone", "Accessibility", "Keychain Access", "Certificate Assistant", "Create a Certificate"}
USER_DOCS = ["README.md", "docs/guide.md", "docs/CONTRIBUTING.md", "CONTEXT.md"]
KEY_NAMES = {"upArrow": "Up Arrow", "downArrow": "Down Arrow", "leftArrow": "Left Arrow", "rightArrow": "Right Arrow",
             "pageUp": "Page Up", "pageDown": "Page Down", "return": "Return", "space": "Space", "delete": "Delete",
             "deleteForward": "Forward Delete", "escape": "Escape", "tab": "Tab", "home": "Home", "end": "End"}
KEY_RE = re.compile(r"((?:(?:Control|Option|Shift|Command)-)+)(Up Arrow|Down Arrow|Left Arrow|Right Arrow|Page Up|"
                    r"Page Down|Forward Delete|Return|Space|Delete|Escape|Tab|Home|End|[A-Za-z0-9](?![A-Za-z0-9])|"
                    r"[=+\-,.;/\[\]'])")


def code_keys():
    """The (modifiers, key) pairs of the keyboard shortcuts of Sources/DirigibleApp."""
    def key_name(tok):
        tok = tok.strip()
        m = re.fullmatch(r'(?:KeyEquivalent\()?"(.)"\)?', tok)
        if m:
            return m.group(1).upper()
        m = re.fullmatch(r"\.(\w+)", tok)
        return KEY_NAMES.get(m.group(1)) if m else None

    def mods(tok):
        if tok is None:
            return frozenset({"Command"})
        return frozenset(w.capitalize() for w in re.findall(r"\.(command|option|shift|control)", tok))

    found = set()
    for f in (root / "Sources/DirigibleApp").rglob("*.swift"):
        t = f.read_text(encoding="utf-8")
        for m in re.finditer(r"(?:KeyboardShortcut|\.keyboardShortcut)\(\s*([^,()]+(?:\([^()]*\))?)\s*"
                             r"(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\s*\)", t):
            k = key_name(m.group(1))
            if k:
                found.add((mods(m.group(2)), k))
        for m in re.finditer(r"key:\s*([^,]+?),\s*modifiers:\s*(\[[^\]]*\]|\.\w+)", t):
            k = key_name(m.group(1))
            if k:
                found.add((mods(m.group(2)), k))
    return found


def rule_menus():
    en, es = strings("en"), strings("es")
    if not en or not (root / "Sources/DirigibleApp").is_dir():
        return

    def norm(part):
        return quotes(part).replace(ELL, "...")

    def matcher(values):
        """A set for the plain strings and one regex for the strings with a format specifier."""
        plain, formats = set(), []
        for v in values:
            v = norm(v)
            if "%" in v:
                formats.append(re.sub(r"%(\d\\\$)?(@|lld|ld|d|f|\\\.\d+f)", ".+", re.escape(v).replace("\\%", "%")))
            else:
                plain.add(v)
        pattern = re.compile("(?:" + "|".join(formats) + r")\Z") if formats else None
        return lambda part: part in plain or bool(pattern and pattern.match(part))

    any_string = matcher(list(en.values()) + list(es.values()))
    menu_string = matcher([v for d in (en, es) for k, v in d.items() if k.startswith("menu.")])
    titles = MENU_TITLES | {v for d in (en, es) for k, v in d.items() if re.fullmatch(r"menu\.[a-z]+", k)}

    def known(part, menu_only, top):
        part = norm(part)
        if re.fullmatch(r"(Undo|Redo)( .+)?", part):
            return top in ("Edit", "Edición")
        return part in MACOS or (menu_string if menu_only else any_string)(part)

    keys = code_keys()
    menu_lines = {n for n, _ in section("docs/guide.md", r"^## Menu commands and keys")}
    for doc in USER_DOCS:
        for n, line in enumerate(lines_of(doc), 1):
            if line.lstrip().startswith("#"):
                continue
            keytexts = [m.group(1) for m in re.finditer(r"\*\*[^*]+ > [^*]+\*\* \(([^)]+)\)", line)]
            if doc == "docs/guide.md" and n in menu_lines and line.lstrip().startswith("|"):
                keytexts.append(line.rstrip(" |").rsplit("|", 1)[-1])
            for kt in keytexts:
                for m in KEY_RE.finditer(kt):
                    k = m.group(2).upper() if len(m.group(2)) == 1 else m.group(2)
                    if (frozenset(w for w in m.group(1).split("-") if w), k) not in keys:
                        miss(f"{doc}:{n}", f"menu key {m.group(0)} is no keyboard shortcut of Sources/DirigibleApp")
            for m in re.finditer(r"\*\*([^*]+?)\*\*", line):
                body = m.group(1)
                if " > " not in body:
                    continue
                parts = [p.strip() for p in body.split(" > ")]
                is_menu = norm(parts[0]) in titles
                for i, part in enumerate(parts):
                    menu_only = is_menu and i > 0
                    top = norm(parts[0])
                    if not known(part, menu_only, top):
                        why = " (the menu string ends in an ellipsis)" if known(part.rstrip(".") + "...", menu_only, top) else ""
                        miss(f"{doc}:{n}", f"path **{body}**: no {'menu' if menu_only else 'UI'} string \"{part}\"{why}")


def rule_menutables():
    en = strings("en")
    sec = section("docs/guide.md", r"^## Menu commands and keys")
    if not en or not sec:
        return
    heads, cur = {}, None
    for n, line in sec:
        m = re.match(r"^### (.+)", line)
        if m:
            cur = m.group(1).strip()
            heads[cur] = []
            continue
        if cur:
            heads[cur].append(n)
            if line.startswith("|") and re.search(r"\|\s*-\s*\|\s*$", line):
                miss(f"docs/guide.md:{n}", "the key cell is '-' (write None)")
    whole = "\n".join(line for _, line in sec)
    for k, v in en.items():
        parts = k.split(".")
        if parts[0] != "menu" or len(parts) < 3 or parts[1].capitalize() not in heads:
            continue
        if any(".".join(parts[:i]) in en for i in range(3, len(parts))):
            continue
        name = v.rstrip(ELL)
        if "%" not in name and f"**{name}**" not in whole:
            miss("docs/guide.md", f"## Menu commands and keys has no **{name}** ({k})")


def rule_decstatus():
    records = sorted((root / "docs/decisions").glob("[0-9][0-9][0-9][0-9]-*.md"))
    states = feature_states()
    status = {}
    for p in records:
        body = p.read_text(encoding="utf-8")
        m = re.search(r"^- Status: (.+)$", body, re.M)
        status[p.name[:4]] = m.group(1).strip() if m else None
        if m and m.group(1).strip() == "proposed" and states is not None:
            head = body.split("\n## ", 1)[0]
            if not any(not states.get(f, "").startswith("done") and f in states for f in re.findall(r"\bF\d{2,3}\b", head)):
                miss(f"docs/decisions/{p.name}", "Status proposed, and its head names no F-ID that is not done")
    for n, line in enumerate(lines_of("docs/README.md"), 1):
        m = re.match(r"^\| \[(\d{4})\]\([^)]*\) \|[^|]*\| ([^|]+) \|", line)
        if m and status.get(m.group(1)) is not None and m.group(2).strip() != status[m.group(1)]:
            miss(f"docs/README.md:{n}", f"{m.group(1)} has the Status cell '{m.group(2).strip()}', and its record has '{status[m.group(1)]}'")


def rule_releases():
    rel = text("docs/requirements/releases.md")
    if rel is None:
        return
    done = []
    for state in (feature_states() or {}).values():
        if state.startswith("done, "):
            state = re.sub(r"; Later:.*", "", state)
            state = re.sub(r" \([^)]*\)", "", state)
            m = re.match(r"done, Release (\d+)\b", state)
            if m:
                done.append(int(m.group(1)))
    for sec in re.split(r"(?m)^(?=## )", rel):
        m = re.match(r"## Release (\d+):", sec)
        if m and not re.search(r"(?m)^(- )?Status: closed\b", sec) and any(d > int(m.group(1)) for d in done):
            miss("docs/requirements/releases.md", f"Release {m.group(1)} has no `Status: closed` line, and a feature of a later release is done: run the docs coherence pass of docs/workflow/release-cycle.md, End of a release, then add Status: closed")
    for n, line in enumerate(rel.splitlines(), 1):
        if re.search(r"\(done\b", line):
            miss(f"docs/requirements/releases.md:{n}", "a `(done ...)` mark: features.md holds the state")


def rule_deccites():
    nums = {p.name[:4] for p in (root / "docs/decisions").glob("[0-9][0-9][0-9][0-9]-*.md")}
    if not nums:
        return
    top = max(nums)
    gap = re.search(r"The numbers ([0-9, and]+) are not used", text("docs/README.md") or "")
    files = md_files("README.md", "AGENTS.md", "CODING_STANDARDS.md", "CONTEXT.md", "docs", ".claude/skills", ".claude/agents")
    for f in files:
        rel = f.relative_to(root)
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if gap and gap.group(0) in line:
                continue
            plain = re.sub(r"`[^`]*`", "", line)
            for m in re.finditer(r"(?<![\w.:/-])(0\d{3})(?![\w:/-]|\.\d)", plain):
                if re.search(r"(item|backlog|items) $", plain[:m.start()], re.IGNORECASE) or m.group(1) > top:
                    continue
                if m.group(1) not in nums:
                    miss(f"{rel}:{n}", f"{m.group(1)} names no decision record: {line.strip()[:90]}")


def rule_private():
    public = ("README.md", "docs/guide.md", "docs/requirements/", "docs/decisions/", "docs/research/")
    files = md_files("README.md", "docs")
    files += sorted((root / "docs").rglob("*.tsv")) if (root / "docs").is_dir() else []
    for f in files:
        rel = str(f.relative_to(root))
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if rel.startswith(public):
                for m in re.finditer(r"\.scratchpads/[A-Za-z0-9]", line):
                    miss(f"{rel}:{n}", f"a path into the local scratch folder: {m.group(0)}")
            if rel.startswith("docs/"):
                for m in re.finditer(r"\b(?:items?|backlog) (?:item )?\d{3,4}\b", line, re.IGNORECASE):
                    miss(f"{rel}:{n}", f"a backlog number, which a reader cannot open: {m.group(0)}")


for rule in (rule_menus, rule_menutables, rule_decstatus, rule_releases, rule_deccites, rule_private):
    rule()
for m in misses:
    print(m, file=sys.stderr)
sys.exit(1 if misses else 0)
