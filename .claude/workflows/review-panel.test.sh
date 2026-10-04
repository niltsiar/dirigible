#!/bin/bash
# Run the lens selection of review-panel.js with real args and stub agents: the default lenses of
# each target, an explicit lens list, an unknown key, an empty selection, and a paths scope with
# no changed file. Check that only warning and critical findings go to a skeptic, and that the
# result lists the nits of each lens under `nits`. Run by `make test-hooks`.
set -euo pipefail
PANEL="$(cd "$(dirname "$0")" && pwd)/review-panel.js" exec node - <<'JS'
const src = require('fs').readFileSync(process.env.PANEL, 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const FIVE = ['context-engineering', 'prompt-engineering', 'harness-engineering', 'eval-engineering', 'compound-engineering']
const PATHS = ['AGENTS.md', '.claude/skills', '.claude/agents', 'docs/workflow']
let failures = 0
const fail = msg => { console.log(`FAIL: ${msg}`); failures++ }

// The stub agent returns the file list for the paths scope step (label 'scope'), the findings of
// `found[lens]` (none by default) with one checked entry for each lens, and a skeptic verdict that
// upholds each finding. The stub pipeline passes the lens to each stage.
async function run(args, files = [], found = {}) {
  const prompts = [], labels = []
  const agent = async (prompt, opts) => {
    prompts.push(prompt)
    labels.push(opts.label)
    if (opts.label === 'scope') return { files }
    if (opts.label.startsWith('verify:')) return { verdicts: [0, 1, 2].map(index => ({ index, upheld: true, reason: 'stub' })) }
    return { findings: found[opts.label.slice('review:'.length)] || [], checked: ['stub'] }
  }
  const pipeline = (items, ...stages) => Promise.all(items.map(async item => {
    let r = item
    for (const stage of stages) r = await stage(r, item)
    return r
  }))
  const result = await new AsyncFunction('args', 'log', 'agent', 'pipeline', src)(args, () => {}, agent, pipeline)
  return { keys: result.panel.map(p => p.lens), missing: result.missing, prompts, labels, panel: result.panel }
}

const finding = (severity, title) => ({ severity, title, location: 'a.sh:1', failure: 'f', evidence: 'e' })
const titles = list => JSON.stringify((list || []).map(f => f.title))

// Only warning and critical findings go to the skeptic of a lens; nits go to `nits`.
async function expectNits(name, found, want) {
  try {
    const got = await run({ target: 'diff', lenses: ['premortem'] }, [], { premortem: found })
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

async function expectKeys(name, args, keys, missing = [], files = []) {
  try {
    const got = await run(args, files)
    if (JSON.stringify(got.keys) !== JSON.stringify(keys)) fail(`${name}: keys ${JSON.stringify(got.keys)}, want ${JSON.stringify(keys)}`)
    if (JSON.stringify(got.missing) !== JSON.stringify(missing)) fail(`${name}: missing ${JSON.stringify(got.missing)}, want ${JSON.stringify(missing)}`)
    return got
  } catch (error) {
    fail(`${name}: threw ${error.message}`)
  }
}

async function expectThrow(name, args, pattern, files = []) {
  try {
    await run(args, files)
    fail(`${name}: did not throw`)
  } catch (error) {
    if (!pattern.test(error.message)) fail(`${name}: threw [${error.message}], want ${pattern}`)
  }
}

;(async () => {
  const scoped = await expectKeys('five lenses on a skills diff', { target: 'diff', lenses: FIVE, paths: PATHS }, FIVE, [], ['AGENTS.md'])
  if (scoped && !scoped.prompts.some(p => p.includes(`git diff main...HEAD -- ${PATHS.join(' ')}`))) fail('five lenses on a skills diff: no reviewer prompt has the paths scope')
  await expectKeys('default diff lenses', { target: 'diff' }, ['premortem', 'devils-advocate', 'architecture', 'code-quality'])
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
  await expectThrow('a relative worktree', { target: 'diff', worktree: 'wt' }, /absolute path/)
  await expectKeys('default plan lenses', { target: 'plan' }, ['premortem', 'devils-advocate', 'architecture'])
  await expectKeys('an unknown key', { target: 'diff', lenses: ['premortem', 'nope'] }, ['premortem'], ['nope'])
  await expectThrow('only an unknown key', { target: 'diff', lenses: ['nope'] }, /no lens/)
  await expectThrow('an empty lens list', { target: 'diff', lenses: [] }, /no lens/)
  await expectThrow('a paths scope with no changed file', { target: 'diff', paths: ['no/such/path'] }, /no changed file/)
  await expectNits('a lens with only nits', [finding('nit', 'nit one'), finding('nit', 'nit two')], { verify: false, nits: ['nit one', 'nit two'] })
  await expectNits('a nit and a warning', [finding('nit', 'nit one'), finding('warning', 'warn one')], { verify: true, sent: ['warn one'], nits: ['nit one'] })
  await expectNits('a critical finding', [finding('critical', 'crit one')], { verify: true, sent: ['crit one'], nits: [] })
  if (failures) { console.log(`${failures} failure(s)`); process.exit(1) }
  console.log('review-panel.test.sh: all cases pass')
})()
JS
