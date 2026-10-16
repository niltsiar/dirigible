#!/bin/bash
# Run the lens selection of review-panel.js with real args and stub agents: the default lenses and
# maxRounds of each target, the convergence prompt of each round after round 1, an explicit lens
# list, a named lens outside its gates, an unknown key,
# an empty selection, a paths scope with no changed file, the read limits of the lens and skeptic
# prompts, and the absolute run paths of a worktree call. Check that only warning and critical
# findings go to a skeptic, that the skeptic is the typed agent of .claude/agents/skeptic.md with a
# fallback of the model and effort of that file, and that the result lists the nits of each lens
# under `nits`. Run by `make test-hooks`.
set -euo pipefail
PANEL="$(cd "$(dirname "$0")" && pwd)/review-panel.js" exec node - <<'JS'
const src = require('fs').readFileSync(process.env.PANEL, 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const FIVE = ['context-engineering', 'prompt-engineering', 'harness-engineering', 'eval-engineering', 'compound-engineering']
const PATHS = ['AGENTS.md', '.claude/skills', '.claude/agents', 'docs/workflow']
let failures = 0
const fail = msg => { console.log(`FAIL: ${msg}`); failures++ }

// The stub agent returns the file list for the diff scope step (label 'scope'), the findings of
// `found[lens]` (none by default) with one checked entry for each lens, and a skeptic verdict that
// upholds each finding. The stub pipeline passes the lens to each stage.
async function run(args, files = ['a.sh'], found = {}, typedFails = false) {
  const prompts = [], labels = [], options = []
  const agent = async (prompt, opts) => {
    prompts.push(prompt)
    labels.push(opts.label)
    options.push(opts)
    if (opts.label === 'scope') return { files }
    if (typedFails && opts.agentType) throw new Error('no agent type')
    if (opts.label.startsWith('verify:')) return { verdicts: [0, 1, 2].map(index => ({ index, upheld: true, reason: 'stub' })) }
    return { findings: found[opts.label.slice('review:'.length)] || [], checked: ['stub'] }
  }
  const pipeline = (items, ...stages) => Promise.all(items.map(async item => {
    let r = item
    for (const stage of stages) r = await stage(r, item)
    return r
  }))
  const result = await new AsyncFunction('args', 'log', 'agent', 'pipeline', src)(args, () => {}, agent, pipeline)
  return { keys: result.panel.map(p => p.lens), missing: result.missing, prompts, labels, options, panel: result.panel, maxRounds: result.maxRounds }
}

// The model and effort lines of the frontmatter of an agent file.
const front = name => {
  const head = require('fs').readFileSync(require('path').join(require('path').dirname(process.env.PANEL), `../agents/${name}.md`), 'utf8').split('---')[1]
  return Object.fromEntries(['model', 'effort'].map(k => [k, (head.match(new RegExp(`^${k}: (.+)$`, 'm')) || [])[1]]))
}

const finding = (severity, title) => ({ severity, title, location: 'a.sh:1', failure: 'f', evidence: 'e' })
const titles = list => JSON.stringify((list || []).map(f => f.title))

// Only warning and critical findings go to the skeptic of a lens; nits go to `nits`.
async function expectNits(name, found, want) {
  try {
    const got = await run({ target: 'diff', lenses: ['premortem'] }, ['a.sh'], { premortem: found })
    const lens = got.panel[0] || {}
    const verify = got.prompts.filter((p, i) => got.labels[i] === 'verify:premortem')
    if (verify.length !== (want.verify ? 1 : 0)) fail(`${name}: ${verify.length} verify:premortem calls, want ${want.verify ? 1 : 0}`)
    for (const t of want.sent || []) if (!verify.some(p => p.includes(t))) fail(`${name}: the skeptic did not get ${t}`)
    for (const t of want.nits) if (verify.some(p => p.includes(t))) fail(`${name}: the skeptic got the nit ${t}`)
    if (titles(lens.nits) !== JSON.stringify(want.nits)) fail(`${name}: nits ${titles(lens.nits)}, want ${JSON.stringify(want.nits)}`)
    if (titles(lens.survived) !== JSON.stringify(want.sent || [])) fail(`${name}: survived ${titles(lens.survived)}, want ${JSON.stringify(want.sent || [])}`)
    if (lens.raised !== found.length) fail(`${name}: raised ${lens.raised}, want ${found.length}`)
  } catch (error) {
    fail(`${name}: threw ${error.message}`)
  }
}

async function expectKeys(name, args, keys, missing = [], files = ['a.sh']) {
  try {
    const got = await run(args, files)
    if (JSON.stringify(got.keys) !== JSON.stringify(keys)) fail(`${name}: keys ${JSON.stringify(got.keys)}, want ${JSON.stringify(keys)}`)
    if (JSON.stringify(got.missing) !== JSON.stringify(missing)) fail(`${name}: missing ${JSON.stringify(got.missing)}, want ${JSON.stringify(missing)}`)
    return got
  } catch (error) {
    fail(`${name}: threw ${error.message}`)
  }
}

async function expectThrow(name, args, pattern, files = ['a.sh']) {
  try {
    await run(args, files)
    fail(`${name}: did not throw`)
  } catch (error) {
    if (!pattern.test(error.message)) fail(`${name}: threw [${error.message}], want ${pattern}`)
  }
}

;(async () => {
  const scoped = await expectKeys('five lenses on a skills diff', { target: 'diff', lenses: FIVE, paths: PATHS }, FIVE, [], ['AGENTS.md'])
  if (scoped && !scoped.prompts.some(p => p.includes(`git diff --stat main...HEAD -- ${PATHS.join(' ')}`))) fail('five lenses on a skills diff: no reviewer prompt has the paths scope')
  // The code gate runs the code-review skill in place of the code-quality lens (interrogate Step
  // 3), so code-quality runs only by name.
  await expectKeys('default diff lenses', { target: 'diff' }, ['premortem', 'devils-advocate', 'architecture'])
  await expectKeys('code-quality by name at the diff gate', { target: 'diff', lenses: ['code-quality'] }, ['code-quality'])
  // A worktree arg: each git command of the scope, reviewer, and skeptic prompts runs with -C, and
  // each prompt names the tree for file reads. The main checkout has an empty diff for a branch
  // that lives in a worktree.
  try {
    const got = await run({ target: 'diff', lenses: ['premortem'], paths: ['a.sh'], worktree: '/abs/wt' }, ['a.sh'], { premortem: [finding('warning', 'warn one')] })
    for (const label of ['scope', 'review:premortem', 'verify:premortem']) {
      const prompt = got.prompts[got.labels.indexOf(label)]
      if (!prompt) { fail(`worktree: no ${label} prompt`); continue }
      if (!prompt.includes('`git -C /abs/wt diff')) fail(`worktree: the ${label} prompt has no git -C /abs/wt diff`)
      if (/`git diff/.test(prompt)) fail(`worktree: the ${label} prompt has a git diff with no -C`)
      if (!prompt.includes('read each tracked file there')) fail(`worktree: the ${label} prompt does not name the tree for file reads`)
    }
  } catch (error) {
    fail(`worktree: threw ${error.message}`)
  }
  // The fallback of a failed typed agent reads the agent file of the worktree.
  try {
    const got = await run({ target: 'diff', lenses: ['premortem'], worktree: '/abs/wt' }, ['a.sh'], {}, true)
    if (!got.prompts.some(p => p.startsWith('Read /abs/wt/.claude/agents/premortem.md'))) fail('worktree fallback: no read of the worktree agent file')
  } catch (error) {
    fail(`worktree fallback: threw ${error.message}`)
  }
  // The skeptic is a typed agent: its contract is in its agent file, not in the prompt. Its
  // fallback reads the worktree agent file and runs with the model and effort of that file.
  try {
    const one = [finding('warning', 'warn one')]
    const typed = await run({ target: 'diff', lenses: ['premortem'] }, ['a.sh'], { premortem: one })
    const i = typed.labels.indexOf('verify:premortem')
    if (typed.options[i]?.agentType !== 'skeptic') fail(`skeptic: agentType ${typed.options[i]?.agentType}, want skeptic`)
    if ((typed.prompts[i] || '').includes('A finding is upheld only when')) fail('skeptic: the prompt repeats the contract of skeptic.md')
    const fallback = await run({ target: 'diff', lenses: ['premortem'], worktree: '/abs/wt' }, ['a.sh'], { premortem: one }, true)
    const j = fallback.labels.lastIndexOf('verify:premortem')
    if (!(fallback.prompts[j] || '').startsWith('Read /abs/wt/.claude/agents/skeptic.md')) fail('skeptic fallback: no read of the worktree agent file')
    const want = front('skeptic')
    for (const key of ['model', 'effort']) {
      if (!want[key] || fallback.options[j]?.[key] !== want[key]) fail(`skeptic fallback: ${key} ${fallback.options[j]?.[key]}, want ${want[key]} of skeptic.md`)
    }
  } catch (error) {
    fail(`skeptic: threw ${error.message}`)
  }
  await expectThrow('a relative worktree', { target: 'diff', worktree: 'wt' }, /absolute path/)
  await expectKeys('default plan lenses', { target: 'plan' }, ['premortem', 'devils-advocate', 'architecture'])
  // Each gate has 2 rounds at most when the caller gives no maxRounds (deliver, class table).
  for (const target of ['plan', 'diff']) {
    try {
      const got = await run({ target })
      if (got.maxRounds !== 2) fail(`a ${target} with no maxRounds: maxRounds ${got.maxRounds}, want 2`)
    } catch (error) {
      fail(`a ${target} with no maxRounds: threw ${error.message}`)
    }
  }
  // Each round after round 1 is a convergence round: no middle round reviews openly.
  try {
    const got = await run({ target: 'plan', round: 2, maxRounds: 3, prior: ['x'] })
    const prompt = got.prompts[got.labels.indexOf('review:premortem')] || ''
    if (!prompt.includes('the convergence round')) fail('round 2 of 3: the reviewer prompt is not the convergence prompt')
  } catch (error) {
    fail(`round 2 of 3: threw ${error.message}`)
  }
  // A named lens runs only at its gates; an empty gates list holds each target.
  await expectKeys('a diff-only lens at the plan gate', { target: 'plan', lenses: ['code-quality', 'premortem'] }, ['premortem'])
  await expectThrow('only a diff-only lens at the plan gate', { target: 'plan', lenses: ['code-quality'] }, /no lens/)
  await expectKeys('a doc lens at the plan gate', { target: 'plan', lenses: ['harness-engineering'] }, ['harness-engineering'])
  await expectKeys('an unknown key', { target: 'diff', lenses: ['premortem', 'nope'] }, ['premortem'], ['nope'])
  await expectThrow('only an unknown key', { target: 'diff', lenses: ['nope'] }, /no lens/)
  await expectThrow('an empty lens list', { target: 'diff', lenses: [] }, /no lens/)
  await expectThrow('a paths scope with no changed file', { target: 'diff', paths: ['no/such/path'] }, /no changed file/, [])
  // A diff with no changed file (the main checkout of a branch in a worktree) stops the panel too.
  await expectThrow('a diff with no changed file', { target: 'diff' }, /no changed file/, [])
  await expectNits('a lens with only nits', [finding('nit', 'nit one'), finding('nit', 'nit two')], { verify: false, nits: ['nit one', 'nit two'] })
  await expectNits('a nit and a warning', [finding('nit', 'nit one'), finding('warning', 'warn one')], { verify: true, sent: ['warn one'], nits: ['nit one'] })
  await expectNits('a critical finding', [finding('critical', 'crit one')], { verify: true, sent: ['crit one'], nits: [] })
  // Smaller reads: a diff lens reads the stat first and one file per call; a skeptic reads only
  // the files that a finding names and greps the ledger; a plan lens still reads every file that
  // the plan references.
  try {
    const got = await run({ target: 'diff', lenses: ['premortem'] })
    const prompt = got.prompts[got.labels.indexOf('review:premortem')] || ''
    if (!prompt.includes('diff --stat') || !prompt.includes('one file per call')) fail('diff lens: no stat-first, one-file-per-call read')
  } catch (error) {
    fail(`diff lens reads: threw ${error.message}`)
  }
  try {
    const got = await run({ target: 'plan', lenses: ['premortem'], scope: '/abs/plan.md', ledger: '/abs/d.tsv' }, ['a.sh'], { premortem: [finding('warning', 'warn one')] })
    const lens = got.prompts[got.labels.indexOf('review:premortem')] || ''
    const skeptic = got.prompts[got.labels.indexOf('verify:premortem')] || ''
    if (!lens.includes('every file it references')) fail('plan lens: it no longer reads every file that the plan references')
    if (!skeptic.includes('only the files that a finding names')) fail('plan skeptic: no read limit to the files that a finding names')
    if (skeptic.includes('every file it references')) fail('plan skeptic: it reads every file that the plan references')
    if (!/Grep \/abs\/d\.tsv for the result tokens .*NOT VERIFIED.* and the words of each finding: a finding whose failure already happened in this run is upheld/.test(skeptic)) fail('plan skeptic: no grep of the ledger with the upheld-failure clause in one sentence')
    if (skeptic.includes('Read /abs/d.tsv first')) fail('plan skeptic: it reads the whole ledger')
  } catch (error) {
    fail(`plan skeptic reads: threw ${error.message}`)
  }
  // With a worktree, a relative ledger, prior file, or plan scope resolves in the worktree, which
  // has no .scratchpads: each throws. With no worktree, a relative ledger still works.
  await expectThrow('a relative ledger with a worktree', { target: 'diff', worktree: '/abs/wt', ledger: 'rel.tsv' }, /absolute path/)
  await expectThrow('a relative prior file with a worktree', { target: 'diff', worktree: '/abs/wt', round: 2, prior: ['rel.md'] }, /absolute path/)
  await expectThrow('a relative plan scope with a worktree', { target: 'plan', worktree: '/abs/wt', scope: 'rel/plan.md' }, /absolute path/)
  await expectKeys('a relative ledger with no worktree', { target: 'diff', ledger: 'rel.tsv' }, ['premortem', 'devils-advocate', 'architecture'])
  await expectKeys('absolute paths with a worktree', { target: 'plan', worktree: '/abs/wt', scope: '/abs/plan.md', ledger: '/abs/d.tsv' }, ['premortem', 'devils-advocate', 'architecture'])
  // A plan with a worktree and no scope does not throw: the default plan names the main checkout,
  // which holds .scratchpads (code gate item D).
  try {
    const got = await run({ target: 'plan', worktree: '/abs/wt', ledger: '/abs/d.tsv' })
    if (!got.prompts.some(p => p.includes('git -C /abs/wt rev-parse --path-format=absolute --git-common-dir'))) fail('a plan with a worktree and no scope: no prompt names the main checkout of the default plan')
  } catch (error) {
    fail(`a plan with a worktree and no scope: threw ${error.message}`)
  }
  if (failures) { console.log(`${failures} failure(s)`); process.exit(1) }
  console.log('review-panel.test.sh: all cases pass')
})()
JS
