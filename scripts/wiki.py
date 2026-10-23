#!/usr/bin/env python3
"""The local wiki of the backlog, the run log, and the lessons.

Usage: scripts/wiki.py <command> [<argument>...]
  init                                     Make an empty wiki. It refuses an existing path.
  path                                     Print the wiki path.
  list <status> [--taken <run>]            Print one line for each item of a status.
  count <status>                           Print the number of items of a status.
  show <id>...                             Print the page hash and the page of each item.
  seed [--prs]                             Fill an empty wiki from the feature list and the release
                                           plan. --prs adds the deferred and follow-up bullets of the
                                           merged pull requests (a read of gh).
  add <status> --from <file>               Add an item. Line 1 of the file is the title (8 words
                                           or fewer), line 2 the description (12 words or fewer),
                                           line 3 is blank, and the body follows.
  edit <id> --expect <hash> --from <file>  Change the title, description, and body of an item. The
                                           hash is the one that show printed. A page that changed
                                           since then gives exit 75: run show again.
  move <id> <status>                       Change the status of an item.
  take <id> <run>                          Mark an item as taken by a run.
  lesson <key> --from <file>               Append the lines of the file to the lesson page of a key.
  lessons [--seen-once]                    Print each lesson line, or each seen-once line.
  log --from <file>                        Append the lines of the file to the log.
  runs                                     Print the log lines. A later row of a run follows the
                                           earlier one: readers take the last row of a run.
  reserve --from <file>                    Add one decision number entry: "<number> <title>
                                           (run <run folder>)".
  numbers                                  Print the line of the decision numbers.
  now                                      Print the state: counts, taken items, open runs, and
                                           the last 15 log lines.
  lint                                     Check the pages, the index files, and the links.
Free text comes only from a file, never from an argument: write the file with the Write tool. The
tool removes the file after its commit and keeps it after a refusal.
Where: $DIRIGIBLE_WIKI, else the folder dirigible-wiki beside the main checkout of the repo that
holds this script (so it is the same from each worktree).
Each write takes an exclusive flock on .git/wiki-write.lock of the wiki, polled for up to
DIRIGIBLE_WIKI_LOCK_WAIT seconds (default 30), then exit 75. The kernel drops the lock when its
holder dies. Under the lock, a write refuses a dirty wiki tree and a .git/index.lock, exits 1, and
prints the repair. Each write stages only its own paths and makes one commit.
Exit codes: 0 done, 1 refused, 2 bad use, 75 try again.
scripts/wiki.test.sh tests it.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

STATUSES = ("next", "later", "done", "dropped")
PAGE_TYPES = ("Item", "Lesson", "Log", "Now", "Register")
LOG_LINES_IN_NOW = 15
TITLE_WORDS = 8
DESCRIPTION_WORDS = 12

SCRIPT = Path(__file__).resolve()
REPO = SCRIPT.parent.parent
DATE_RE = re.compile(r"(20[0-9]{2}-[0-9]{2})-[0-9]{2}")
KEY_RE = re.compile(r"\b((?:NEW-[A-Z]+-[a-z0-9]+(?:-[a-z0-9]+)*|[A-Z]+-[0-9]{3})/[a-z]+)\b")
KEY_ARG_RE = re.compile(r"^(?:NEW-[A-Z]+-[a-z0-9]+(?:-[a-z0-9]+)*|[A-Z]+-[0-9]{3})/[a-z]+$")
RUN_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]*$")
ID_RE = re.compile(r"^[0-9]{4,}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
ENTRY_RE = re.compile(r"^[0-9]{4} [^,\n]+ \(run [0-9a-z-]+\)$")
GIT_ENV_DROP = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE")
GIT_ENV = {k: v for k, v in os.environ.items() if k not in GIT_ENV_DROP}
# The wiki is a local repo that only this tool writes: a commit needs no identity and no signing.
COMMIT_FLAGS = ["-c", "user.name=dirigible-wiki", "-c", "user.email=wiki@localhost", "-c", "commit.gpgsign=false"]
REGISTER_HEAD = ('Decision numbers taken or reserved (reserve at Phase 2, one entry "<number> <title> '
                 '(run <run folder>)"; the next free number is after the last entry): ')


class Stop(Exception):
    """A refusal: the message goes to stderr and the exit code is code."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


# ---------- files, git, and paths ----------

def read_text(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    with open(temp, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    os.replace(temp, path)


def git(cwd: Path | str, *args: str, input: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["git", "-C", str(cwd), *args], input=input, capture_output=True, text=True,
                          env=GIT_ENV, check=False)
    if check and proc.returncode != 0:
        raise Stop(f"git {' '.join(args[:2])} failed in {cwd}: {proc.stderr.strip()}")
    return proc


def main_checkout() -> Path:
    common = git(REPO, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    return Path(common).parent


def wiki_path() -> Path:
    given = os.environ.get("DIRIGIBLE_WIKI")
    path = Path(given) if given else main_checkout().parent / "dirigible-wiki"
    if (path / ".git").exists() and not (path / ".git").is_dir():
        raise Stop(f"{path} has a .git file, not a .git folder: it is the work tree of a worktree. "
                   "Set DIRIGIBLE_WIKI to another path.")
    return path


def open_wiki() -> Path:
    path = wiki_path()
    if not (path / ".git").is_dir() or not (path / "wiki").is_dir():
        raise Stop(f"no wiki at {path}. Run scripts/wiki.py init to make it, or set DIRIGIBLE_WIKI to "
                   "the path of a wiki.")
    return path


@contextlib.contextmanager
def write_lock(wiki: Path):
    """Hold the write lock of the wiki and check that the wiki is clean."""
    wait = float(os.environ.get("DIRIGIBLE_WIKI_LOCK_WAIT", "30"))
    fd = os.open(wiki / ".git" / "wiki-write.lock", os.O_RDWR | os.O_CREAT, 0o644)
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise Stop(f"another write holds the lock of {wiki} after {wait:g} s; run the same command again", 75)
            time.sleep(0.05)
    try:
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        check_clean(wiki)
        yield
    finally:
        os.close(fd)


def check_clean(wiki: Path) -> None:
    repair = (f"A write stopped part way. Run `git -C {wiki} status`. Commit a whole page with "
              f"`git -C {wiki} add -- <path>` and then `git -C {wiki} commit -m 'wiki: repair'`, restore "
              f"a half change of a tracked page with `git -C {wiki} restore -- <path>`, or delete a half "
              "new page. Delete .git/index.lock only when no git process runs in the wiki.")
    if (wiki / ".git" / "index.lock").exists():
        raise Stop(f"{wiki}/.git/index.lock exists. {repair}")
    dirty = git(wiki, "status", "--porcelain").stdout
    if dirty.strip():
        raise Stop(f"the wiki tree is not clean ({dirty.splitlines()[0]}). {repair}")


def commit(wiki: Path, paths: list[str], message: str) -> None:
    git(wiki, "add", "--", *paths)
    git(wiki, *COMMIT_FLAGS, "commit", "-q", "-F", "-", input=message)


# ---------- pages ----------

def words(text: str) -> int:
    return len(text.split())


def render_page(fields: list[tuple[str, str]], lines: list[str]) -> str:
    head = "".join(f"{k}: {v}\n" for k, v in fields)
    return "---\n" + head + "---\n\n" + "".join(line + "\n" for line in lines)


def parse_page(text: str) -> tuple[dict[str, str], list[str]] | None:
    end = text.find("\n---\n\n", 3)
    if not text.startswith("---\n") or end < 0:
        return None
    body = text[end + 6:]
    fields: dict[str, str] = {}
    for row in text[4:end + 1].splitlines():
        key, _, value = row.partition(": ")
        fields[key.rstrip(":")] = json.loads(value) if value.startswith('"') else value
    return fields, (body[:-1].split("\n") if body else [])


QUOTED_FIELDS = ("title", "description", "group", "source")
FIELD_ORDER = ("type", "title", "description", "status", "source", "runs", "taken", "group", "generated")


class Page:
    def __init__(self, path: Path, fields: dict[str, str], lines: list[str]):
        self.path, self.fields, self.lines = path, fields, lines

    @property
    def id(self) -> str:
        return self.path.stem

    def text(self) -> str:
        keys = [k for k in FIELD_ORDER if k in self.fields] + [k for k in self.fields if k not in FIELD_ORDER]
        return render_page([(k, json.dumps(self.fields[k], ensure_ascii=False) if k in QUOTED_FIELDS
                             else self.fields[k]) for k in keys], self.lines)


def read_page(path: Path) -> Page | None:
    if not path.is_file():
        return None
    parsed = parse_page(read_text(path))
    return Page(path, parsed[0], parsed[1]) if parsed else None


def pages_in(folder: Path, kind: str) -> list[Page]:
    pages = (read_page(p) for p in sorted(folder.glob("*.md"), key=lambda p: (len(p.stem), p.stem)) if p.name != "index.md")
    return [p for p in pages if p and p.fields.get("type") == kind]


def item_pages(wiki: Path) -> list[Page]:
    return pages_in(wiki / "wiki" / "items", "Item")


def lesson_pages(wiki: Path) -> list[Page]:
    return pages_in(wiki / "wiki" / "lessons", "Lesson")


def log_pages(wiki: Path) -> list[Page]:
    return pages_in(wiki / "wiki" / "log", "Log")


def register_page(wiki: Path) -> Page:
    page = read_page(wiki / "wiki" / "decision-numbers.md")
    if page is None:
        raise Stop(f"{wiki}/wiki/decision-numbers.md is not a page; run scripts/wiki.py lint")
    return page


def item_line(page: Page) -> str:
    title, description = page.fields.get("title", ""), page.fields.get("description", "")
    return f"{title}: {description}" if description else title


def open_runs(lines: list[str]) -> list[tuple[str, str]]:
    last: dict[str, tuple[str, str]] = {}
    for line in lines:
        cells = [c.strip() for c in line.split("|")]
        if line.startswith("|") and len(cells) >= 5 and re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}-", cells[1]):
            last[cells[1]] = (cells[2], cells[3])
    return [(name, goal) for name, (goal, status) in last.items() if status == "open"]


# ---------- generated files ----------

def generate(wiki: Path) -> dict[str, str]:
    """The text of each generated file, as a map from its path in the wiki to its text."""
    items = item_pages(wiki)
    out: dict[str, str] = {}
    out["wiki/index.md"] = (
        '---\nokf_version: "0.2"\n---\n\n# Index\n\n'
        "- [Next items](next/index.md): the items to do soon.\n"
        "- [Later items](later/index.md): the items that wait.\n"
        "- [Done and dropped items](done/index.md): the closed items.\n"
        "- [Lessons](lessons/index.md): the learnings, one page for each cause key.\n"
        "- [Log](log/index.md): the run rows and the log lines, one page for each month.\n"
        "- [Now](now.md): the state of the backlog and the runs.\n"
        "- [Decision numbers](decision-numbers.md): the decision numbers taken or reserved.\n")
    for status, title in (("next", "Next items"), ("later", "Later items")):
        rows = "".join(f"- [{p.id}](../items/{p.id}.md): {item_line(p)}\n" for p in items
                       if p.fields.get("status") == status)
        out[f"wiki/{status}/index.md"] = f"# {title}\n\nItems with the status {status}, by ID.\n\n{rows}"
    rows = "".join(f"- [{p.id}](../items/{p.id}.md): {p.fields.get('status')}: {item_line(p)}\n" for p in items
                   if p.fields.get("status") in ("done", "dropped"))
    out["wiki/done/index.md"] = f"# Done and dropped items\n\nItems with the status done or dropped, by ID.\n\n{rows}"
    rows = "".join(f"- [{p.fields.get('key', p.id)}]({p.path.name}): {len(p.lines)} lines\n" for p in lesson_pages(wiki))
    out["wiki/lessons/index.md"] = f"# Lessons\n\nOne page for each cause key. Each line is one learning.\n\n{rows}"
    logs = log_pages(wiki)
    rows = "".join(f"- [{p.id}]({p.path.name}): {len(p.lines)} lines\n" for p in logs)
    out["wiki/log/index.md"] = f"# Log\n\nOne page for each month, oldest first.\n\n{rows}"
    lines = [line for page in logs for line in page.lines]
    counts = ", ".join(f"{s} {sum(1 for p in items if p.fields.get('status') == s)}" for s in STATUSES)
    taken = [f"- {p.id} (taken: {p.fields['taken']}) {p.fields.get('title', '')}" for p in items
             if p.fields.get("status") == "next" and p.fields.get("taken")]
    runs = [f"- {name} ({goal})" for name, goal in open_runs(lines)]
    tail = [line for line in lines if line.strip()][-LOG_LINES_IN_NOW:]
    out["wiki/now.md"] = render_page([("type", "Now")], (
        ["# Now", "", f"Items: {counts}.", "", "## Next items taken by a run", ""] + (taken or ["None."]) +
        ["", "## Open runs", ""] + (runs or ["None."]) +
        ["", f"## Last {LOG_LINES_IN_NOW} log lines", ""] + (tail or ["None."])))
    return out


def this_month() -> str:
    return datetime.date.today().strftime("%Y-%m")


def init_files() -> dict[str, str]:
    """The files of a new wiki that generate() does not make."""
    month = this_month()
    return {
        "CLAUDE.md": SCHEMA,
        "templates/item.md": ITEM_TEMPLATE,
        "templates/lesson.md": LESSON_TEMPLATE,
        "wiki/decision-numbers.md": render_page([("type", "Register")], []),
        f"wiki/log/{month}.md": render_page([("type", "Log"), ("month", month)], []),
    }


SCHEMA = """# Dirigible wiki - behavior contract

The local wiki of the backlog, the run log, and the lessons of the Dirigible repo. It is local only
and has no remote, because the backlog holds tester notes. The tool is `scripts/wiki.py` of the
repo. Never edit a page by hand: each write goes through the tool, under a lock, with one commit.

## Layers

- `raw/`: frozen sources. Never change a file there.
- `wiki/`: the pages. `wiki/index.md` is the root index and holds `okf_version`.
- `templates/`: the shape of an `Item` page and of a `Lesson` page.

## Pages

- `Item` (`wiki/items/<nnnn>.md`): one backlog item. Fields: `title` (8 words or fewer),
  `description` (12 words or fewer), `status` (next, later, done, or dropped), `source`, `runs`,
  `taken`, `group`, `generated`. The body holds the current state of the item. History is in git.
- `Lesson` (`wiki/lessons/<key>.md`): the learning lines of one cause key.
- `Log` (`wiki/log/<YYYY-MM>.md`): the run rows and the log lines of one month.
- `Now` (`wiki/now.md`): generated. `Register` (`wiki/decision-numbers.md`): the decision numbers.
- Each `index.md` and `now.md` is generated. A page that no `index.md` links fails the lint.

## Rules

- Write only with `scripts/wiki.py`. Text comes only from a file: `--from <file>`.
- After a change, `scripts/wiki.py lint` must pass.
- ASCII punctuation only: no em or en dashes.
"""

ITEM_TEMPLATE = """---
type: Item
title: "<8 words or fewer>"
description: "<12 words or fewer>"
status: next
source: "<where the item came from>"
runs: <run folders that touched it>
taken: <run folder that works on it>
group: "<optional group>"
generated: <YYYY-MM-DD>
---

<The current state of the item: what to do, why, and the evidence. No history.>
"""

LESSON_TEMPLATE = """---
type: Lesson
key: <ID>/<class>
---

- <YYYY-MM-DD> seen-once <run folder> <ID>/<class>: <one learning, one line>
"""


# ---------- write helpers ----------

def store(wiki: Path, changes: dict[str, str], message: str) -> None:
    """Write the changed files, rewrite each generated file that differs, and make one commit."""
    for rel, text in changes.items():
        write_file(wiki / rel, text)
    paths = list(changes)
    for rel, text in generate(wiki).items():
        if not (wiki / rel).exists() or read_text(wiki / rel) != text:
            write_file(wiki / rel, text)
            paths.append(rel)
    commit(wiki, paths, message)


def read_from(arg: str) -> tuple[Path, str]:
    path = Path(arg)
    if not path.is_file():
        raise Stop(f"the --from file {arg} does not exist", 2)
    return path, read_text(path)


def lines_of(text: str) -> list[str]:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def parse_item_text(text: str) -> tuple[str, str, list[str]]:
    lines = lines_of(text)
    if lines and lines[0] == "---":
        raise Stop("the file starts with a front matter block; give the title on line 1 and the body from line 4", 2)
    if len(lines) < 4 or lines[2] != "":
        raise Stop("the file needs the title on line 1, the description on line 2, a blank line, and the body", 2)
    title, description, body = lines[0].strip(), lines[1].strip(), lines[3:]
    if not title or words(title) > TITLE_WORDS:
        raise Stop(f"the title has {words(title)} words; it needs 1 to {TITLE_WORDS}", 2)
    if not description or words(description) > DESCRIPTION_WORDS:
        raise Stop(f"the description has {words(description)} words; it needs 1 to {DESCRIPTION_WORDS}", 2)
    if not any(line.strip() for line in body):
        raise Stop("the body is empty", 2)
    return title, description, body


def item_text(status: str, title: str, description: str, body: list[str], **extra: str) -> str:
    fields = {"type": "Item", "title": title, "description": description, "status": status, **extra,
              "generated": datetime.date.today().isoformat()}
    return Page(Path("item.md"), fields, body).text()


def cut_words(text: str) -> tuple[str, str]:
    """Split text into a title of the first 8 words and a description of the next 12 words."""
    found = text.split()
    return " ".join(found[:TITLE_WORDS]), " ".join(found[TITLE_WORDS:TITLE_WORDS + DESCRIPTION_WORDS])


def next_id(wiki: Path) -> str:
    ids = [int(p.stem) for p in (wiki / "wiki" / "items").glob("*.md") if ID_RE.match(p.stem)]
    return f"{max(ids, default=0) + 1:04d}"


def find_item(wiki: Path, item_id: str) -> Page:
    if not ID_RE.match(item_id):
        raise Stop(f"{item_id} is not an item ID (four digits)", 2)
    page = read_page(wiki / "wiki" / "items" / f"{item_id}.md")
    if page is None:
        raise Stop(f"no item {item_id}")
    return page


def page_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_status(status: str) -> str:
    if status not in STATUSES:
        raise Stop(f"{status} is not a status: use {', '.join(STATUSES)}", 2)
    return status


def lesson_name(key: str) -> str:
    return key.replace("/", "--")


def route_log(lines: list[str], first: str) -> dict[str, list[str]]:
    """Group lines by the month of their first date. A line with no date joins the line before it."""
    months: dict[str, list[str]] = {}
    current = first
    for line in lines:
        found = DATE_RE.search(line)
        if found:
            current = found.group(1)
        months.setdefault(current, []).append(line)
    return months


# ---------- commands ----------

def cmd_path(args) -> None:
    print(wiki_path())


def cmd_init(args) -> None:
    wiki = wiki_path()
    if wiki.exists():
        raise Stop(f"{wiki} exists; init makes a new wiki only. Choose another path with DIRIGIBLE_WIKI.")
    wiki.mkdir(parents=True)
    (wiki / "raw").mkdir()
    git(wiki, "init", "-q", "-b", "main")
    files = init_files()
    for rel, text in files.items():
        write_file(wiki / rel, text)
    generated = generate(wiki)
    for rel, text in generated.items():
        write_file(wiki / rel, text)
    commit(wiki, sorted(set(files) | set(generated)), "wiki: init")
    print(wiki)


def require_new_wiki(wiki: Path) -> None:
    """Refuse a wiki that holds an item, a lesson, a changed log page, or decision numbers."""
    if item_pages(wiki):
        raise Stop(f"the wiki at {wiki} already holds an item page; seed and import need a new wiki")
    if lesson_pages(wiki):
        raise Stop(f"the wiki at {wiki} already holds a lesson page; seed and import need a new wiki")
    for page in log_pages(wiki):
        if read_text(page.path) != render_page([("type", "Log"), ("month", page.id)], []):
            raise Stop(f"the wiki at {wiki} holds a log page that differs from its init text: {page.path.name}")
    if register_page(wiki).lines:
        raise Stop(f"the wiki at {wiki} already holds decision numbers; seed and import need a new wiki")


def feature_items(path: Path) -> tuple[list[tuple[str, str, str, str, list[str]]], set[str]]:
    """The features that are not done and not dropped, and the IDs of those features."""
    items, open_ids = [], set()
    for line in lines_of(read_text(path)):
        if not re.match(r"^\| F[0-9]+ \|", line):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 5:
            raise Stop(f"{path.name}: a feature row has {len(cells)} cells, not 5: {line[:60]}")
        fid, feature, source, state, req = cells
        if state.startswith(("done", "Dropped")):
            continue
        if not state.startswith(("Later", "Release")):
            raise Stop(f"{path.name}: {fid} has the unknown state {state[:40]}")
        title, _ = cut_words(f"{fid} {feature}")
        description = " ".join(state.split()[:DESCRIPTION_WORDS])
        body = [f"{fid} {feature}. From: {source}. State: {state}. Req: {req}."]
        items.append(("later" if state.startswith("Later") else "next", title, description, "features.md", body))
        open_ids.add(fid)
    return items, open_ids


def release_items(path: Path, open_ids: set[str]) -> list[tuple[str, str, str, str, list[str]]]:
    """The numbered run items of the releases file that name a feature that is not done."""
    items, release = [], None
    for line in lines_of(read_text(path)):
        heading = re.match(r"^## Release ([0-9]+)", line)
        numbered = re.match(r"^([0-9]+)\. (.*)", line)
        if heading:
            release = heading.group(1)
        elif numbered and release and open_ids & set(re.findall(r"\bF[0-9]+\b", line)):
            name = re.match(r"\*\*(.+?)\*\*", numbered.group(2))
            title, _ = cut_words(name.group(1).rstrip(".") if name else numbered.group(2))
            items.append(("next", title, f"Release {release} item {numbered.group(1)}", f"releases.md, Release {release}",
                          [numbered.group(2)]))
    return items


def pr_items() -> list[tuple[str, str, str, str, list[str]]]:
    """The deferred and follow-up bullets of the merged pull request bodies (a read of gh)."""
    try:
        proc = subprocess.run(["gh", "pr", "list", "--state", "merged", "--limit", "1000", "--json", "number,body"],
                              capture_output=True, text=True, cwd=REPO, check=False)
    except FileNotFoundError:
        raise Stop("seed --prs needs the gh command, and it is not installed") from None
    if proc.returncode != 0:
        raise Stop(f"gh pr list failed: {proc.stderr.strip()[:200]}")
    items = []
    for pr in json.loads(proc.stdout):
        for line in (pr.get("body") or "").splitlines():
            found = re.match(r"^\s*[-*]\s+(.*\b(?:deferred|follow[- ]up)\b.*)$", line, re.I)
            if found:
                title, description = cut_words(f"PR {pr['number']}: {found.group(1)}")
                items.append(("later", title, description, f"pr {pr['number']}", [found.group(1), "", f"From PR {pr['number']}."]))
    return items


def cmd_seed(args) -> None:
    wiki = open_wiki()
    docs = REPO / "docs" / "requirements"
    for name in ("features.md", "releases.md"):
        if not (docs / name).is_file():
            raise Stop(f"seed reads {docs}/{name}, and it does not exist")
    items, open_ids = feature_items(docs / "features.md")
    items += release_items(docs / "releases.md", open_ids)
    if args.prs:
        items += pr_items()
    with write_lock(wiki):
        require_new_wiki(wiki)
        first = int(next_id(wiki))
        changes = {f"wiki/items/{first + n:04d}.md": item_text(status, title, description, body, source=source)
                   for n, (status, title, description, source, body) in enumerate(items)}
        store(wiki, changes, f"wiki: seed {len(items)} items")
    print(f"seeded {len(items)} items: {sum(1 for i in items if i[0] == 'next')} next, "
          f"{sum(1 for i in items if i[0] == 'later')} later")


def cmd_list(args) -> None:
    wiki = open_wiki()
    status = check_status(args.status)
    for page in item_pages(wiki):
        taken = page.fields.get("taken", "")
        if page.fields.get("status") == status and (not args.taken or taken == args.taken):
            print(f"{page.id} {item_line(page)}" + (f" (taken: {taken})" if taken else ""))


def cmd_count(args) -> None:
    wiki = open_wiki()
    status = check_status(args.status)
    print(sum(1 for p in item_pages(wiki) if p.fields.get("status") == status))


def cmd_show(args) -> None:
    wiki = open_wiki()
    for n, item_id in enumerate(args.ids):
        page = find_item(wiki, item_id)
        if n:
            print()
        print(f"hash: {page_hash(page.path)}")
        sys.stdout.write(read_text(page.path))


def cmd_add(args) -> None:
    wiki = open_wiki()
    status = check_status(args.status)
    src, text = read_from(args.src)
    title, description, body = parse_item_text(text)
    with write_lock(wiki):
        item_id = next_id(wiki)
        store(wiki, {f"wiki/items/{item_id}.md": item_text(status, title, description, body)},
              f"wiki: add item {item_id} ({status})")
    src.unlink()
    print(item_id)


def cmd_edit(args) -> None:
    wiki = open_wiki()
    if not HASH_RE.match(args.expect):
        raise Stop("--expect needs the 64-character hash that show prints", 2)
    src, text = read_from(args.src)
    title, description, body = parse_item_text(text)
    with write_lock(wiki):
        page = find_item(wiki, args.id)
        if page_hash(page.path) != args.expect:
            raise Stop(f"the page changed; run scripts/wiki.py show {args.id} again", 75)
        page.fields.update(title=title, description=description)
        page.lines = body
        store(wiki, {f"wiki/items/{args.id}.md": page.text()}, f"wiki: edit item {args.id}")
    src.unlink()


def cmd_move(args) -> None:
    wiki = open_wiki()
    status = check_status(args.status)
    with write_lock(wiki):
        page = find_item(wiki, args.id)
        page.fields["status"] = status
        store(wiki, {f"wiki/items/{args.id}.md": page.text()}, f"wiki: move item {args.id} to {status}")


def cmd_take(args) -> None:
    wiki = open_wiki()
    if not RUN_RE.match(args.run):
        raise Stop(f"{args.run} is not a run folder name (YYYY-MM-DD-<slug>)", 2)
    with write_lock(wiki):
        page = find_item(wiki, args.id)
        holder = page.fields.get("taken", "")
        if holder and holder != args.run:
            raise Stop(f"item {args.id} is taken by {holder}")
        runs = [r for r in page.fields.get("runs", "").split(", ") if r]
        if args.run not in runs:
            runs.append(args.run)
        page.fields.update(taken=args.run, runs=", ".join(runs))
        store(wiki, {f"wiki/items/{args.id}.md": page.text()}, f"wiki: item {args.id} taken by {args.run}")


def cmd_lesson(args) -> None:
    wiki = open_wiki()
    key = args.key
    if not KEY_ARG_RE.match(key):
        raise Stop(f"{key} is not a cause key (<ID>/<class>)", 2)
    src, text = read_from(args.src)
    new = lines_of(text)
    if not new:
        raise Stop("the file has no line", 2)
    for line in new:
        found = KEY_RE.search(line)
        if not line.startswith("- ") or not found or found.group(1) != key:
            raise Stop(f"each line starts with '- ' and has {key} as its first cause key: {line[:60]}", 2)
    with write_lock(wiki):
        rel = f"wiki/lessons/{lesson_name(key)}.md"
        page = read_page(wiki / rel) or Page(wiki / rel, {"type": "Lesson", "key": key}, [])
        page.lines = page.lines + new
        store(wiki, {rel: page.text()}, f"wiki: lesson {key}")
    src.unlink()


def cmd_lessons(args) -> None:
    wiki = open_wiki()
    for page in lesson_pages(wiki):
        for line in page.lines:
            if not args.seen_once or " seen-once " in line:
                print(line)


def cmd_log(args) -> None:
    wiki = open_wiki()
    src, text = read_from(args.src)
    lines = lines_of(text)
    if not lines:
        raise Stop("the file has no line", 2)
    with write_lock(wiki):
        changes = {}
        for month, new in route_log(lines, this_month()).items():
            rel = f"wiki/log/{month}.md"
            page = read_page(wiki / rel) or Page(wiki / rel, {"type": "Log", "month": month}, [])
            page.lines = page.lines + new
            changes[rel] = page.text()
        store(wiki, changes, f"wiki: log {len(lines)} lines")
    src.unlink()


def cmd_runs(args) -> None:
    wiki = open_wiki()
    for page in log_pages(wiki):
        for line in page.lines:
            print(line)


def cmd_reserve(args) -> None:
    wiki = open_wiki()
    src, text = read_from(args.src)
    lines = lines_of(text)
    if len(lines) != 1 or not ENTRY_RE.match(lines[0]):
        raise Stop('the file holds one entry: "<number> <title> (run <run folder>)"', 2)
    entry = lines[0]
    with write_lock(wiki):
        page = register_page(wiki)
        if not page.lines:
            page.lines = [REGISTER_HEAD + entry + "."]
        elif re.search(rf"(^|[:,] ){entry[:4]} ", page.lines[0]):
            raise Stop(f"the number {entry[:4]} has an entry already")
        else:
            page.lines = [page.lines[0][:-1] + ", " + entry + "."]
        store(wiki, {"wiki/decision-numbers.md": page.text()}, f"wiki: reserve decision number {entry[:4]}")
    src.unlink()


def cmd_numbers(args) -> None:
    for line in register_page(open_wiki()).lines:
        print(line)


def cmd_now(args) -> None:
    wiki = open_wiki()
    page = read_page(wiki / "wiki" / "now.md")
    if page is None:
        raise Stop(f"{wiki}/wiki/now.md is not a page; run scripts/wiki.py lint")
    print("\n".join(page.lines))


def cmd_lint(args) -> None:
    wiki = open_wiki()
    root = wiki / "wiki"
    problems: list[str] = []
    linked: set[Path] = set()
    pages = [p for p in sorted(root.rglob("*.md")) if p.name != "index.md"]
    for path in pages:
        rel = path.relative_to(wiki)
        page = read_page(path)
        if page is None:
            problems.append(f"{rel}: no front matter")
            continue
        kind = page.fields.get("type")
        if kind not in PAGE_TYPES:
            problems.append(f"{rel}: type {kind!r} is not one of {', '.join(PAGE_TYPES)}")
        if kind == "Item":
            if page.fields.get("status") not in STATUSES:
                problems.append(f"{rel}: status {page.fields.get('status')!r} is not one of {', '.join(STATUSES)}")
            title, description = page.fields.get("title", ""), page.fields.get("description", "")
            if not title or words(title) > TITLE_WORDS:
                problems.append(f"{rel}: the title has {words(title)} words; it needs 1 to {TITLE_WORDS}")
            if words(description) > DESCRIPTION_WORDS:
                problems.append(f"{rel}: the description has {words(description)} words; the limit is {DESCRIPTION_WORDS}")
    for path in sorted(root.rglob("*.md")):
        prose = re.sub(r"`[^`\n]*`", "", re.sub(r"```.*?```", "", read_text(path), flags=re.S))
        for target in re.findall(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", prose):
            target = target.split("#")[0]
            if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                continue
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                problems.append(f"{path.relative_to(wiki)}: broken link {target}")
            elif path.name == "index.md":
                linked.add(resolved)
    for path in pages:
        if path.resolve() not in linked:
            problems.append(f"{path.relative_to(wiki)}: no index.md links this page")
    for rel, text in generate(wiki).items():
        if not (wiki / rel).exists():
            problems.append(f"{rel}: missing")
        elif read_text(wiki / rel) != text:
            problems.append(f"{rel}: differs from its generated text")
    if problems:
        for problem in problems:
            print(f"lint: {problem}", file=sys.stderr)
        raise Stop(f"lint failed with {len(problems)} problem(s)")
    print(f"lint ok: {len(pages)} pages")


# ---------- command line ----------

class Parser(argparse.ArgumentParser):
    def error(self, message: str):
        self.print_usage(sys.stderr)
        sys.stderr.write(f"{self.prog}: {message}. Free text comes only from a file: use --from <file>.\n")
        raise SystemExit(2)


def build_parser() -> argparse.ArgumentParser:
    parser = Parser(prog="wiki.py", description="The local wiki of the backlog, the log, and the lessons.")
    sub = parser.add_subparsers(dest="command", required=True, parser_class=Parser)

    def command(name: str, fn, *params: str, src: bool = False, **options):
        p = sub.add_parser(name)
        for param in params:
            p.add_argument(param)
        if src:
            p.add_argument("--from", dest="src", required=True, metavar="FILE")
        for flag, kwargs in options.items():
            p.add_argument("--" + flag.replace("_", "-"), **kwargs)
        p.set_defaults(fn=fn)
        return p

    command("init", cmd_init)
    command("path", cmd_path)
    command("list", cmd_list, "status", taken={"default": None})
    command("count", cmd_count, "status")
    command("show", cmd_show).add_argument("ids", nargs="+", metavar="id")
    command("seed", cmd_seed, prs={"action": "store_true"})
    command("add", cmd_add, "status", src=True)
    command("edit", cmd_edit, "id", src=True, expect={"required": True})
    command("move", cmd_move, "id", "status")
    command("take", cmd_take, "id", "run")
    command("lesson", cmd_lesson, "key", src=True)
    command("lessons", cmd_lessons, seen_once={"action": "store_true"})
    command("log", cmd_log, src=True)
    command("runs", cmd_runs)
    command("reserve", cmd_reserve, src=True)
    command("numbers", cmd_numbers)
    command("now", cmd_now)
    command("lint", cmd_lint)
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.fn(args)
    except Stop as stop:
        print(f"wiki.py: {stop}", file=sys.stderr)
        return stop.code
    except BrokenPipeError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
