#!/bin/bash
# Run the lens selection of review-panel.js with real args and stub agents: the default lenses of
# each target, an explicit lens list, an unknown key, an empty selection, and a paths scope with
# no changed file. Run by `make test-hooks`.
set -euo pipefail
PANEL="$(cd "$(dirname "$0")" && pwd)/review-panel.js" exec node - <<'JS'
const src = require('fs').readFileSync(process.env.PANEL, 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const FIVE = ['context-engineering', 'prompt-engineering', 'harness-engineering', 'eval-engineering', 'compound-engineering']
const PATHS = ['AGENTS.md', '.claude/skills', '.claude/agents', 'docs/workflow']
let failures = 0
const fail = msg => { console.log(`FAIL: ${msg}`); failures++ }

// The stub agent returns the file list for the paths scope step (label 'scope'), and a clean
// review with one checked entry for each lens. The stub pipeline passes the lens to each stage.
async function run(args, files = []) {
  const prompts = []
  const agent = async (prompt, opts) => {
    prompts.push(prompt)
    return opts.label === 'scope' ? { files } : { findings: [], checked: ['stub'] }
  }
  const pipeline = (items, ...stages) => Promise.all(items.map(async item => {
    let r = item
    for (const stage of stages) r = await stage(r, item)
    return r
  }))
  const result = await new AsyncFunction('args', 'log', 'agent', 'pipeline', src)(args, () => {}, agent, pipeline)
  return { keys: result.panel.map(p => p.lens), missing: result.missing, prompts }
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
  await expectKeys('default plan lenses', { target: 'plan' }, ['premortem', 'devils-advocate', 'architecture'])
  await expectKeys('an unknown key', { target: 'diff', lenses: ['premortem', 'nope'] }, ['premortem'], ['nope'])
  await expectThrow('only an unknown key', { target: 'diff', lenses: ['nope'] }, /no lens/)
  await expectThrow('an empty lens list', { target: 'diff', lenses: [] }, /no lens/)
  await expectThrow('a paths scope with no changed file', { target: 'diff', paths: ['no/such/path'] }, /no changed file/)
  if (failures) { console.log(`${failures} failure(s)`); process.exit(1) }
  console.log('review-panel.test.sh: all cases pass')
})()
JS
