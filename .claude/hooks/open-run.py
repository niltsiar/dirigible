# Find the open deliver run of a working directory. Read by stop-guard.sh, pre-compact.sh, and agent-guard.sh, so the hooks use one rule.
# open_run(cwd) returns (run folder, how) or None.
# A run is open when the run.md in .scratchpads/runs/<name>/ of the main checkout has a `- Status: open`
# line. The main checkout is the parent of the git common dir, so a run worktree finds the same runs.
#   - In a run worktree: the open run whose last `- Branch:` line names the branch of cwd (`branch`).
#   - In the main checkout: the open run whose folder holds cwd (`cwd`), else the open run with the
#     newest decisions.tsv row (`newest row`). The lead works there on `main`, so a branch never
#     names its run. With two active runs and cwd at the checkout top, the newest row can be wrong.
import os
import re
import subprocess


def git(cwd, *args):
    try:
        done = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def main_checkout(cwd):
    common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return os.path.dirname(common) if common else ""


def newest_row(folder):
    rows = [line for line in read(os.path.join(folder, "decisions.tsv")).splitlines() if line.strip()]
    return rows[-1].split("\t")[0] if rows else ""


def is_open(folder):
    """Whether the run.md of a run folder has a `- Status: open` line."""
    return re.search(r"^- Status: open\s*$", read(os.path.join(folder, "run.md")), re.M) is not None


def open_run(cwd):
    """The open run of cwd as a (folder, how) pair, or None."""
    main = main_checkout(cwd)
    if not main:
        return None
    runs = os.path.join(main, ".scratchpads", "runs")
    try:
        names = sorted(os.listdir(runs))
    except OSError:
        return None
    open_runs = {}
    for name in names:
        folder = os.path.join(runs, name)
        if is_open(folder):
            open_runs[folder] = read(os.path.join(folder, "run.md"))
    top = git(cwd, "rev-parse", "--show-toplevel")
    if top and os.path.realpath(top) != os.path.realpath(main):
        branch = git(cwd, "symbolic-ref", "--short", "HEAD")
        named = [f for f, text in open_runs.items() if (re.findall(r"^- Branch: *(\S+)", text, re.M) or [""])[-1] == branch]
        how = "branch"
    else:
        here = os.path.realpath(cwd)
        named = [f for f in open_runs if here == os.path.realpath(f) or here.startswith(os.path.realpath(f) + os.sep)]
        how = "cwd"
        if not named:
            named, how = list(open_runs), "newest row"
    if not named:
        return None
    return max(named, key=lambda f: (newest_row(f), os.path.getmtime(os.path.join(f, "run.md")))), how


def worktree_of(cwd, branch):
    """The worktree path where `branch` is checked out, or an empty string."""
    path = ""
    for line in git(cwd, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "branch refs/heads/" + branch:
            return path
    return ""


def first_unticked(folder):
    """The first unticked line of the Slices section of run.md, else of the whole file."""
    text = read(os.path.join(folder, "run.md"))
    section = re.search(r"^## Slices\s*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    for scope in (section.group(1) if section else "", text):
        found = re.search(r"^\s*- \[ \] .*$", scope, re.M)
        if found:
            return found.group(0).strip()
    return ""


def run_branch(folder):
    """The value of the last `- Branch:` line of run.md, or an empty string."""
    found = re.findall(r"^- Branch: *(\S+)", read(os.path.join(folder, "run.md")), re.M)
    return found[-1] if found else ""


def run_state(folder):
    """The first unticked phase line and whether a `waits: user` line is there."""
    text = read(os.path.join(folder, "run.md"))
    unticked = re.findall(r"^\s*- \[ \] .*$", text, re.M)
    waits = re.search(r"^\s*(- )?waits: user", text, re.M) is not None
    return (unticked[0].strip() if unticked else ""), waits
