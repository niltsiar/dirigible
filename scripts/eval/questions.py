"""Write the question files and the answer prompts of a doc eval (docs/workflow/evals.md, How the
eval runs). Run r of set a and of set b ask the same questions in the same order: the shuffle seed
is the run number only, so a batch effect cannot differ between the sets.

Usage: python3 scripts/eval/questions.py <evals.md> <answer folder> <ID,ID,...> <runs> [<template>]
The template defaults to scripts/eval/prompt-template.md. In it, {EVAL} is the parent folder of
the answer folder (it holds docs-a and docs-b), {OUT} is the answer folder, {S} is the set (a or
b), and {R} is the run. It writes questions-<set>-<run>.txt and prompt-<set>-<run>.md in the answer
folder. scripts/evals-for.test.sh tests it."""
import os
import random
import sys

args = sys.argv[1:]
if len(args) not in (4, 5):
    sys.exit('usage: questions.py <evals.md> <answer folder> <ID,ID,...> <runs> [<template>]')
evals, out, ids, runs = args[0], os.path.abspath(args[1]), args[2].split(','), int(args[3])
here = os.path.dirname(os.path.abspath(__file__))
template = args[4] if len(args) == 5 else os.path.join(here, 'prompt-template.md')
questions = {}
for line in open(evals):
    cells = [c.strip() for c in line.split('|')]
    if len(cells) > 5 and cells[1] in ids:
        questions[cells[1]] = cells[4]
missing = sorted(set(ids) - set(questions))
if missing:
    sys.exit(f'questions.py: no Scenarios row for {" ".join(missing)}')
prompt = open(template).read()
for r in range(1, runs + 1):
    order = ids[:]
    random.Random(r).shuffle(order)
    text = '\n\n'.join(f'{i}: {questions[i]}' for i in order) + '\n'
    for s in 'ab':
        open(f'{out}/questions-{s}-{r}.txt', 'w').write(text)
        filled = prompt.replace('{EVAL}', os.path.dirname(out)).replace('{OUT}', out)
        open(f'{out}/prompt-{s}-{r}.md', 'w').write(filled.replace('{S}', s).replace('{R}', str(r)))
print(f'questions.py: {runs} runs of {len(ids)} questions for sets a and b in {out}')
