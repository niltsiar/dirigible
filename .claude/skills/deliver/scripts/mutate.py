#!/usr/bin/env python3
"""Run source-mutation controls and never leave a mutant in the tree.

Usage: mutate.py [--expect <text>] [--timeout <seconds>] [--switch expr|stmt] <file> <old text> <new text> <log>
                 <build command> <test command> [<old text 2> <new text 2> ...] [--in=<file 2> <old> <new> ...]
       mutate.py --schema <folder> <n>...

One mutant: the script records the SHA-256 of <file>, replaces the one exact copy of <old text> with
<new text> (and of each extra pair, in order: one mutant with several edits), runs <build command>, then <test command> (each with bash -o pipefail -c), writes the raw output
to <log>, restores the file, and checks the hash. Each command runs with pipefail, so a failed
build piped into `tail` is a failed build, not a stale binary under test. It prints one result:
  killed        the build passed and the test failed (exit 0)
  killed (hang) the test ran past --timeout; the script killed it (exit 0)
  survived      the build and the test passed (exit 1)
  BUILD FAILED  the mutant did not build, so it proves nothing (exit 2)
  WRONG FAILURE the test failed, but its output has no <text> of --expect (exit 4); it prints
                up to 10 compared lines that hold ✘, failed, or error
  NO TESTS      the test ran no test: the filter matched nothing (exit 5). The test passed, or
                scripts/test-filter.sh refused a name with a line that starts with
                "test-filter: no test matched " or "test-filter: no test ID matches ", and no line
                of the output starts with "FAIL:"
  LOCK WAIT     the build or the test exited 75, the exit of a scripts/with-lock.sh wait over its
                limit: nothing was tested, run it again (exit 75)
  stopped       SIGINT, SIGTERM, or SIGHUP stopped the run; the files are restored (exit 130)
With --expect, a kill counts only when the output of the test has <text>, for example the
message of the assertion that the control must break. A progress line (a test started or passed)
does not count: it names every test of the filter, also on a run where another test fails. A crash or a trap also fails the test.
With --timeout, a test that runs longer than <seconds> is killed with all its processes, and the
result is a kill: use it for a mutant that makes the code hang (a display loop), which no wait
limit inside the test can stop. With --expect too, a hang is a kill only when <text> came before
the kill: a failure report that hangs (a large value in an assert message) prints no text and
gives WRONG FAILURE. --switch marks a mutant for --schema; one mutant ignores it. Another option
before <file> exits 2: each mutant runs once (mutation-pass.sh), so there is no replay mode.
A lone call (no MUTATION_PASS_HELD) in a git tree with scripts/with-lock.sh runs itself again under
it, before any change, so the build and the test hold the build lock once; mutation-pass.sh sets the
variable. A missing or repeated <old text>, an extra old text with no new text, or an --expect text
that the test cannot print exits 2 before any change. Swift Testing prints each operand of the
outermost comparison of an #expect with its value, for example (rows(model) → [...]) == [], so a
text that spans an operand and its operator never prints: copy the text from the failure output.
The refusal applies only to the #expect and #require conditions of the --exact names of the test
command, found under Tests/, and only when the text is in no string literal under Tests/ and no
condition of those bodies can print it (a copy that starts at the paren after the left operand prints).
A failed restore exits 3. A control that needs two edits (a guard mutant and the fault
that trips it) is one call with two pairs. An extra argument --in=<file> puts the pairs after it
in <file>: one mutant in two files, with each file hashed and restored. Do not nest mutate.py in the test command: the outer
result line then gives the verdict of the inner script, not of the mutant.

--schema: the switch mutants of a batch in one build (mutation-pass.sh calls it). <folder>/<n> holds
the arguments of mutant n, NUL-separated; the call reads only the files that it names. Each old
text must be in its file once. The call puts each one in a switch on its batch number n:
  --switch expr  (dirigibleMutant == n ? (<new>) : (<old>))
  --switch stmt  if dirigibleMutant == n { <new> } else { <old> }
Mutants with the same span and form make one chain. Each mutated file gets, at its end, an import
of Foundation and a file-private let that reads DIRIGIBLE_MUTANT. Then `xcrun swiftc -parse` reads
each .swift file, the build command of the first mutant runs once (its output in
<folder>/build.log), each distinct test command runs once with no DIRIGIBLE_MUTANT (the baseline,
with the largest --timeout of its mutants), and each test command runs with DIRIGIBLE_MUTANT=<n>.
The script prints one line for each mutant:
  <n> <result>: <log>        a result of one mutant (WRONG FAILURE prints no compared lines)
  <n> own build: <reason>    the mutant needs its own build (one mutant call): no --switch, an
                             empty expr new text, another build command, a span that overlaps
                             another span in part, a wrap that swiftc -parse refuses (Swift 6
                             mode; a file whose original does not parse is left to the build), an error
                             line of the build in its file, or a failed baseline of its test
  <n> mutate: <reason>       a refused mutant: incomplete arguments, an old text that is not in
                             its file once, or a build command with a pipe (the build log must
                             keep its error lines)
A build error in files with switches sends the mutants of those files to their own build, and the
batch builds once more; a second failure, or an error with no such file, sends all of them. The
copies of the files are <folder>/<index>.orig, and <folder>/orig.tsv lists the index and the path
of each while the call runs (a SIGKILL or a failed restore leaves it). The exits are 0 (the lines), 2 (a refusal of the
whole call), 3 (a failed restore), and 130 (stopped, after the restore).
In a git tree, a run holds the lock <git dir>/dirigible-mutate.lock (a folder with the pid), so two
runs never mutate one tree; a second run exits 2, and the lock of a dead process is taken over.
"""
import functools, hashlib, os, re, shutil, signal, subprocess, sys

SWITCH = ('\n// The switch of the mutation pass (mutate.py --schema); the restore removes it.\nimport Foundation\n'
          'private let dirigibleMutant = Int(ProcessInfo.processInfo.environment["DIRIGIBLE_MUTANT"] ?? "") ?? 0\n')


class Refused(Exception):
    """A mutant that cannot run. No reason means incomplete arguments."""


class Mutant:
    """The options, the old/new pairs of each file, the log, and the commands of one mutant."""

    def __init__(self, args):
        self.expected = self.timeout = self.form = None
        while args[:1] in (['--expect'], ['--timeout'], ['--switch']):
            if len(args) < 2:
                raise Refused()
            if args[0] == '--expect':
                self.expected = args[1]
            elif args[0] == '--timeout':
                self.timeout = float(args[1])
            elif args[1] in ('expr', 'stmt'):
                self.form = args[1]
            else:
                raise Refused(f'--switch takes expr or stmt, not {args[1]}')
            args = args[2:]
        if args[:1] and args[0].startswith('--'):
            raise Refused(f'unknown option {args[0]}')
        if len(args) < 6:
            raise Refused()
        self.path, old, new, self.log, self.build, self.test = args[:6]
        # The pairs of each file, in order. --in=<file> starts the pairs of another file.
        self.edits = {self.path: [(old, new)]}
        current, rest = self.path, args[6:]
        while rest:
            if rest[0].startswith('--in='):
                current, rest = rest[0][len('--in='):], rest[1:]
                self.edits.setdefault(current, [])
            elif len(rest) < 2 or rest[1].startswith('--in='):
                raise Refused('an extra old text has no new text')
            else:
                self.edits[current].append((rest[0], rest[1]))
                rest = rest[2:]
        reason = self.expected is not None and expect_refusal(self.expected, self.test, 'Tests')
        if reason:
            raise Refused(reason)

    def header(self, out, switch=None):
        out.write(f'# mutation of {self.path}\n')
        for name, pairs in self.edits.items():
            if name != self.path:
                out.write(f'# in {name}\n')
            for old, new in pairs:
                out.write(f'# - {old!r}\n# + {new!r}\n')
        if switch:
            out.write(f'# switch: {self.form} {switch[0]}\n')
        out.write(f'# build: {self.build}' + (f' (one build for the batch: {switch[1]})' if switch else '') + '\n')
        out.write(f'# test: {self.test}\n')
        if self.expected is not None:
            out.write(f'# expect: {self.expected!r}\n')
        if self.timeout is not None:
            out.write(f'# timeout: {self.timeout!r}\n')
        out.flush()


def once(text, old, name):
    if text.count(old) != 1:
        raise Refused(f'the old text is in {name} {text.count(old)} times, not once: {old!r}')


ARROW = '→'
COMPARISONS = ('===', '!==', '==', '!=', '<=', '>=', ' < ', ' > ')


def skip_string(text, i):
    """The index of the quote that closes the string literal that opens at text[i]."""
    i += 1
    while i < len(text) and text[i] != '"':
        i += 2 if text[i] == '\\' else 1
    return i


def closing(text, start):
    """The index after the bracket that closes text[start], skipping string literals."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == '"':
            i = skip_string(text, i)
        elif text[i] in '({[':
            depth += 1
        elif text[i] in ')}]':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def top_level(text):
    """The indexes of the characters of text outside every bracket and string literal."""
    depth, i, found = 0, 0, []
    while i < len(text):
        if text[i] == '"':
            i = skip_string(text, i)
        elif text[i] in '({[':
            depth += 1
        elif text[i] in ')}]':
            depth -= 1
        elif depth == 0:
            found.append(i)
        i += 1
    return found


def conditions(body):
    """The condition (the text up to the first top-level comma) of each #expect and #require in body."""
    found = []
    for opening in re.finditer(r'#(expect|require)\(', body):
        arguments = body[opening.end():closing(body, opening.end() - 1) - 1]
        commas = [i for i in top_level(arguments) if arguments[i] == ',']
        condition = arguments[:commas[0]] if commas else arguments
        if not condition.lstrip().startswith('throws:'):
            found.append(condition)
    return found


def spans_comparison(text, condition):
    """One flag for each copy of `text` in `condition`: True when the copy spans a top-level comparison
    and the end of its left operand, so the failure output never prints it. The paren that closes the
    left operand is the wrapper that Swift Testing prints before the operator: a copy that starts there
    prints."""
    top = set(top_level(condition))
    outside = ''.join(c if i in top else ' ' for i, c in enumerate(condition))
    copies, at = [], condition.find(text)
    while at != -1:
        copies.append(at)
        at = condition.find(text, at + 1)
    if re.search(r'\b(try|await)\b', condition) or re.search(r'&&|\|\||\?\?| \? ', outside):
        return [False] * len(copies)
    operators, i = [], 0
    while i < len(condition):
        for operator in COMPARISONS:
            if i in top and condition.startswith(operator, i):
                start = i + operator.index(operator.strip())
                operators.append((start, start + len(operator.strip()), condition[:start].strip()))
                i += len(operator) - 1
                break
        i += 1
    flags = []
    for at in copies:
        spans = False
        for start, end, left in operators:
            last = len(condition[:start].rstrip()) - 1
            literal = not re.search(r'[A-Za-z_]', left) or re.match(r'[."\d\[]', left)
            wrapper = at == last and condition[at] == ')'
            spans = spans or (not literal and not wrapper and at <= last and at + len(text) >= end)
        flags.append(spans)
    return flags


@functools.lru_cache(maxsize=None)
def swift_tests(folder):
    """The text of each .swift file under folder, and the contents of each one-line string literal in them."""
    texts = []
    for here, _, names in os.walk(folder):
        for name in names:
            if name.endswith('.swift'):
                with open(os.path.join(here, name), errors='replace') as source:
                    texts.append(source.read())
    return texts, [lit for t in texts for lit in re.findall(r'"((?:[^"\\\n]|\\.)*)"', t)]


def expect_refusal(text, test_command, tests_folder):
    """The reason why `text` can never print in a failure of the test command, or None.

    Swift Testing splits only the outermost operator of a condition and prints each operand with its
    value, so a text refuses only when all of these hold: it has no arrow; it is in a condition of an
    #expect or #require in the bodies of the --exact names of the command (with no --exact a sibling
    test can hold the same text alone); that condition has no try, await, or top-level &&, ||, ??, or
    ? (Swift Testing prints an operand of && as written); the text spans a top-level comparison
    operator and the end of its left operand, which is not a literal, and does not start at the paren
    that closes that operand (the wrapper prints before the operator); no string literal under the
    tests folder holds the text (a message prints as written); and no other condition of those
    bodies can print the text."""
    if ARROW in text or '--exact' not in test_command:
        return None
    names = [w.strip('\'"') for w in test_command.split('--exact', 1)[1].split()
             if re.fullmatch(r'[\'"]?[A-Za-z_][A-Za-z0-9_]*[\'"]?', w)]
    texts, literals = swift_tests(tests_folder)
    if any(text in literal for literal in literals):
        return None
    spanning = None
    for name in names:
        for source in texts:
            for declared in re.finditer(r'\bfunc\s+' + re.escape(name) + r'\s*\(', source):
                brace = source.find('{', declared.end())
                body = source[brace:closing(source, brace)] if brace != -1 else ''
                for condition in conditions(body):
                    flags = spans_comparison(text, condition)
                    if not all(flags):
                        return None
                    if flags:
                        spanning = condition
    if spanning:
        return (f'Swift Testing prints each operand of {spanning.strip()!r} with its value, '
                f'so {text!r} never prints; copy the text from the failure output of the test')
    return None


def descendants(pid):
    """The processes under `pid`, also the ones in another process group (a test runner makes one)."""
    table = subprocess.run(['ps', '-A', '-o', 'pid=,ppid='], capture_output=True, text=True).stdout.split()
    children = {}
    for child, parent in zip(table[::2], table[1::2]):
        children.setdefault(int(parent), []).append(int(child))
    found, todo = [], [pid]
    while todo:
        for child in children.get(todo.pop(), []):
            found.append(child)
            todo.append(child)
    return found


def run(command, out, limit=None, env=None):
    """The exit status of `command`, or None when it ran past `limit` seconds."""
    process = subprocess.Popen(['bash', '-o', 'pipefail', '-c', command], stdout=out, stderr=subprocess.STDOUT,
                               start_new_session=True, env=env)
    try:
        return process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        kill_tree(process)
        return None
    except KeyboardInterrupt:
        kill_tree(process)
        raise


def kill_tree(process):
    tree = descendants(process.pid)
    # The group has ended: ESRCH after the wait, and on macOS EPERM while its leader is an
    # unreaped zombie.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (PermissionError, ProcessLookupError):
        pass
    for pid in tree:
        try:
            os.kill(pid, signal.SIGKILL)
        except (PermissionError, ProcessLookupError):
            pass
    process.wait()


def verdict(log, test_start, built, status, expected, build_status=None):
    """The result, the exit code, and the compared failure lines of a WRONG FAILURE."""
    if status is None:
        result, code = 'killed (hang)', 0
    elif build_status == 75 or (built and status == 75):
        result, code = 'LOCK WAIT', 75
    else:
        result, code = ('BUILD FAILED', 2) if not built else (('survived', 1) if status == 0 else ('killed', 0))
    with open(log, errors='replace') as done:
        done.seek(test_start)
        output = done.read()
    # A filter that matches no test passes: that run proves nothing (SwiftPM and Swift Testing lines).
    if code == 1 and ('No matching test cases were run' in output or re.search(r'Test run with 0 tests', output)):
        result, code = 'NO TESTS', 5
    # scripts/test-filter.sh exits 1 and prints one of these two lines for a name that ran no test.
    # A FAIL: line is a shell test (test-filter.test.sh) that failed and may quote the script output.
    if (result == 'killed' and re.search(r'^test-filter: no test (matched|ID matches) ', output, re.M)
            and not re.search(r'^FAIL:', output, re.M)):
        result, code = 'NO TESTS', 5
    compared = []
    if code == 0 and expected is not None:
        # A progress line of each run (a test started or passed) names every test in the filter,
        # so a test name found only there is not a reason for the kill.
        reasons = [line for line in output.splitlines()
                   if not line.lstrip().startswith(('◇', '✔'))
                   and not re.match(r"\s*Test (Case|Suite) '.*' (started|passed)", line)]
        if not any(expected in line for line in reasons):
            result, code = 'WRONG FAILURE', 4
            compared = [line for line in reasons if re.search('✘|failed|error', line, re.I)][:10]
    with open(log, 'a') as out:
        out.write(f'# result: {result}\n')
    return result, code, compared


def stop(signum, frame):
    raise KeyboardInterrupt


# A stop by SIGINT, SIGTERM, or SIGHUP (a closed terminal) restores the files. A background job
# of a shell starts with SIGINT ignored, so SIGINT gets the handler too.
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)


def take_lock():
    """The lock folder in the git dir of the tree, or None outside a git tree. Exits 2 while a live process holds it."""
    found = subprocess.run(['git', 'rev-parse', '--absolute-git-dir'], capture_output=True, text=True)
    if found.returncode:
        return None
    lock = os.path.join(found.stdout.strip(), 'dirigible-mutate.lock')
    for _ in range(2):
        try:
            os.mkdir(lock)
        except FileExistsError:
            try:
                os.kill(int(open(os.path.join(lock, 'pid')).read()), 0)
            except ProcessLookupError:
                shutil.rmtree(lock, ignore_errors=True)
                continue
            except (OSError, ValueError):
                pass  # No pid yet: the holder is between its mkdir and its write.
            print(f'mutate: another mutate.py run holds {lock}; wait for it to end', file=sys.stderr)
            sys.exit(2)
        with open(os.path.join(lock, 'pid'), 'w') as pid:
            pid.write(str(os.getpid()))
        return lock
    print(f'mutate: cannot take {lock}', file=sys.stderr)
    sys.exit(2)


def guarded(backups, digests, work):
    """Runs `work` under the lock, restores each file from its copy, and checks each hash.
    Exits 3 on a failed restore and 130 after a stop; else returns."""
    lock = take_lock()
    for name, backup in backups.items():
        shutil.copyfile(name, backup)
    stopped = False
    try:
        work()
    except KeyboardInterrupt:
        stopped = True
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        for name, backup in backups.items():
            shutil.copyfile(backup, name)
        if lock:
            shutil.rmtree(lock, ignore_errors=True)
    for name, backup in backups.items():
        if hashlib.sha256(open(name, 'rb').read()).hexdigest() != digests[name]:
            print(f'mutate: the restore of {name} failed; the copy is {backup}', file=sys.stderr)
            sys.exit(3)
    return stopped


def hold_lock():
    """Runs a lone call again under scripts/with-lock.sh, so its build and test hold the build lock once
    and a wait for it ends the call before any edit. mutation-pass.sh holds the lock and sets the variable."""
    if os.environ.get('MUTATION_PASS_HELD'):
        return
    top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    lock = os.path.join(top.stdout.strip(), 'scripts', 'with-lock.sh')
    if top.returncode == 0 and os.access(lock, os.X_OK):
        os.execve(lock, [lock, sys.executable, os.path.abspath(__file__)] + sys.argv[1:],
                  {**os.environ, 'MUTATION_PASS_HELD': '1'})


def one(args):
    try:
        mutant = Mutant(args)
        hold_lock()
        digests, texts = {}, {}
        for name, pairs in mutant.edits.items():
            original = open(name, 'rb').read()
            digests[name] = hashlib.sha256(original).hexdigest()
            text = original.decode()
            for old, new in pairs:
                once(text, old, name)
                text = text.replace(old, new)
            texts[name] = text
    except Refused as refused:
        if not refused.args:
            sys.exit(__doc__)
        print(f'mutate: {refused.args[0]}', file=sys.stderr)
        sys.exit(2)
    log = mutant.log
    backups = {name: log + '.orig' + (str(n) if n else '') for n, name in enumerate(mutant.edits)}
    built, build_status, status, start = False, None, 1, 0

    def work():
        nonlocal built, build_status, status, start
        for name, text in texts.items():
            with open(name, 'w') as out:
                out.write(text)
        with open(log, 'w') as out:
            mutant.header(out)
            build_status = run(mutant.build, out)
            built = build_status == 0
            out.flush()
            start = out.tell()
            if built:
                status = run(mutant.test, out, mutant.timeout)

    if guarded(backups, digests, work):
        with open(log, 'a') as out:
            out.write('# result: stopped\n')
        print(f'stopped: {log}')
        sys.exit(130)
    result, code, compared = verdict(log, start, built, status, mutant.expected, build_status)
    print(f'{result}: {log}')
    if compared:
        # The compared failure lines, so the next --expect copies their printed form.
        print('\n'.join(compared))
    sys.exit(code)


def wrap(form, chain, old):
    """The switch text of one span: `chain` is the (n, new) pairs of the mutants on it."""
    if form == 'expr':
        text = f'({old})'
        for n, new in reversed(chain):
            text = f'(dirigibleMutant == {n} ? ({new}) : {text})'
        return text
    return ' else '.join(f'if dirigibleMutant == {n} {{\n{new}\n}}' for n, new in chain) + f' else {{\n{old}\n}}'


def schema(folder, names):
    if not names or not os.path.isdir(folder):
        print('mutate: --schema needs a folder and the numbers of its mutants', file=sys.stderr)
        sys.exit(2)
    mutants, originals, own = {}, {}, {}
    for n in names:
        try:
            mutant = Mutant(open(os.path.join(folder, n), 'rb').read().decode().split('\0')[:-1])
            if re.search(r'(?<!\|)\|(?!\|)', mutant.build):
                raise Refused('the build command has a pipe; a switch build keeps each error line in its log')
            mutant.spans, texts = [], {}  # spans: (real path, start, end, new)
            for name, pairs in mutant.edits.items():
                real = os.path.realpath(name)
                texts[real] = originals.get(real) or open(real, 'rb').read().decode()
                for old, new in pairs:
                    once(texts[real], old, name)
                    start = texts[real].index(old)
                    mutant.spans.append((real, start, start + len(old), new))
            originals.update(texts)  # Only the files of a mutant that is not refused.
        except Refused as refused:
            print(f'{n} mutate: {refused.args[0] if refused.args else "the arguments are not complete"}', flush=True)
            continue
        except (OSError, ValueError) as error:
            print(f'{n} mutate: {error}', flush=True)
            continue
        mutants[n] = mutant

    def demote(ns, reason):
        for n in ns:
            if n in active:
                active.remove(n)
                print(f'{n} own build: {reason}', flush=True)

    active, taken, build = [], [], None
    for n, mutant in mutants.items():
        reason = None
        if mutant.form is None:
            reason = 'the line has no --switch'
        elif mutant.form == 'expr' and any(not new.strip() for *_, new in mutant.spans):
            reason = 'an empty new text has no expr switch'
        elif build is not None and mutant.build != build:
            reason = 'its build command differs from the batch build command'
        else:
            for real, start, end, _ in mutant.spans:
                for other, (real2, start2, end2, form2) in taken:
                    if real == real2 and start < end2 and start2 < end and (start, end, mutant.form) != (start2, end2, form2):
                        reason = f'its span overlaps the span of mutant {other}'
        if reason:
            print(f'{n} own build: {reason}', flush=True)
            continue
        build = mutant.build
        taken += [(n, (real, start, end, mutant.form)) for real, start, end, _ in mutant.spans]
        active.append(n)

    def write():
        """Writes each file with the switches of the active mutants; returns the files with a switch."""
        spans = {}
        for n in active:
            for real, start, end, new in mutants[n].spans:
                spans.setdefault(real, {}).setdefault((start, end, mutants[n].form), []).append((n, new))
        for real, original in originals.items():
            text = original
            for (start, end, form), chain in sorted(spans.get(real, {}).items(), reverse=True):
                text = text[:start] + wrap(form, chain, text[start:end]) + text[end:]
            with open(real, 'w') as out:
                out.write(text + SWITCH if real in spans else text)
        return set(spans)

    def users(files):
        return [n for n in active if any(span[0] in files for span in mutants[n].spans)]

    build_log = os.path.join(folder, 'build.log')

    def parses(path):
        # Swift 6 mode, as the package: Swift 5 mode refuses a bare-slash regex literal.
        return not subprocess.run(['xcrun', 'swiftc', '-parse', '-swift-version', '6', path],
                                  capture_output=True).returncode

    def parsed_original(real):
        """True when the original text parses: only then can a parse error come from a switch."""
        copy = os.path.join(folder, 'original.swift')
        with open(copy, 'w') as out:
            out.write(originals[real])
        return parses(copy)

    listing = os.path.join(folder, 'orig.tsv')

    def work():
        with open(listing, 'w') as out:
            out.writelines(f'{index}\t{real}\n' for index, real in enumerate(originals))
        while True:
            refused = {real for real in write() if real.endswith('.swift') and not parses(real)
                       and parsed_original(real)}
            if not refused:
                break
            demote(users(refused), 'swiftc -parse refuses its switch in ' + ', '.join(sorted(refused)))
        built = False
        for attempt in (1, 2):
            if not active:
                return
            with open(build_log, 'a') as out:
                out.write(f'# batch build {attempt} of mutants {" ".join(active)}: {build}\n')
                out.flush()
                start = out.tell()
                if run(build, out) == 0:
                    built = True
                    break
            with open(build_log, errors='replace') as done:
                done.seek(start)
                files = {os.path.realpath(path) for path in re.findall(r'^(.+?):\d+:\d+: error:', done.read(), re.M)}
            switched = {span[0] for n in active for span in mutants[n].spans}
            if attempt == 2 or not files or not files <= switched:
                demote(list(active), f'the batch build failed ({build_log})')
                return
            demote(users(files), f'the batch build failed in its file ({build_log})')
            write()
        if not built:
            return
        environment = {key: value for key, value in os.environ.items() if key != 'DIRIGIBLE_MUTANT'}
        tests = {}
        for n in active:
            tests.setdefault(mutants[n].test, []).append(n)
        for k, (test, ns) in enumerate(tests.items(), 1):
            limits = [mutants[n].timeout for n in ns if mutants[n].timeout is not None]
            log = os.path.join(folder, f'baseline-{k}.log')
            with open(log, 'w') as out:
                out.write(f'# baseline with no DIRIGIBLE_MUTANT: {test}\n')
                out.flush()
                if run(test, out, max(limits) if limits else None, environment) != 0:
                    demote(ns, f'the baseline failed ({log})')
        for n in list(active):
            mutant = mutants[n]
            with open(mutant.log, 'w') as out:
                mutant.header(out, (n, build_log))
                start = out.tell()
                status = run(mutant.test, out, mutant.timeout, {**environment, 'DIRIGIBLE_MUTANT': n})
            result, _, _ = verdict(mutant.log, start, True, status, mutant.expected)
            print(f'{n} {result}: {mutant.log}', flush=True)

    backups = {real: os.path.join(folder, f'{index}.orig') for index, real in enumerate(originals)}
    digests = {real: hashlib.sha256(text.encode()).hexdigest() for real, text in originals.items()}
    stopped = guarded(backups, digests, work)
    if os.path.exists(listing):  # A stop can come before work() writes it.
        os.remove(listing)  # Each file has its first hash again; only an unclean end leaves the list.
    if stopped:
        print(f'stopped: the files are restored from {folder}')
        sys.exit(130)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--schema']:
        schema(sys.argv[2] if len(sys.argv) > 2 else '', sys.argv[3:])
    else:
        one(sys.argv[1:])
