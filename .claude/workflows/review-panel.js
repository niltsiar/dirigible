export const meta = {
  name: 'review-panel',
  description: 'Lens review panel (premortem, devils advocate, architecture, code quality, or a chosen lens list) on a plan or diff, with a skeptic check per lens',
  whenToUse: 'Plan gate and code gate of the deliver skill. Args: { target: "plan" | "diff", intent: string, scope: string (plan path, or base ref such as main), round?: number (default 1), maxRounds?: number (default 2), prior?: string[] (verdict files of earlier rounds), settled?: string[] (choices the user asked for or the run already accepted; reviewers do not attack them), risk?: "yes" | "no" (the plan risk at a plan gate; at a code gate, the higher of the plan risk and the risk: line of scripts/check-changed.sh origin/main; yes runs each lens at effort high, except in a convergence round, which runs each lens at medium), ledger?: string (path of the decisions.tsv of the run; skeptics uphold a finding whose failure it records; with worktree, ledger, prior, and a plan scope are absolute), lenses?: string[] (lens keys that replace the default lenses of the target; a lens outside its gates is dropped; the five doc lenses context-engineering, prompt-engineering, harness-engineering, eval-engineering, compound-engineering, and code-quality run only this way), paths?: string[] (diff only: limit the diff to these paths; the workflow stops when no changed file matches), worktree?: string (the absolute path of the worktree that holds the branch: git runs with -C and files are read there; a diff with no changed file stops the workflow) }. Round 1 is open and refuses a prior; each other round only checks that earlier fixes converged.',
  phases: [
    { title: 'Review', detail: 'one reviewer agent per lens' },
    { title: 'Verify', detail: 'one skeptic per lens tries to refute its warning and critical findings' },
  ],
}

const target = args && args.target === 'plan' ? 'plan' : 'diff'
const intent = (args && args.intent) || 'No intent given. Derive it from the plan or the commit messages.'
const round = Number(args && args.round) || 1
const maxRounds = Number(args && args.maxRounds) || 2
const prior = (args && Array.isArray(args.prior)) ? args.prior : []
const settled = (args && Array.isArray(args.settled)) ? args.settled : []
const ledger = (args && args.ledger) || ''
// Round 1 reviews openly. Each later round checks convergence only: an open later round keeps
// widening the review and never closes the gate. Each gate has 2 rounds (deliver, class table).
if (round === 1 && prior.length) throw new Error('args.prior is not allowed at round 1, also when args.round is missing: pass no prior at round 1; a convergence round has round 2 or more')
const mode = round === 1 ? 'open' : 'converge'
if (mode !== 'open' && !prior.length) log(`Round ${round} has no prior verdicts. Reviewers cannot see what earlier rounds fixed.`)
const risk = args && args.risk !== undefined ? args.risk : null
if (risk !== null && risk !== 'yes' && risk !== 'no') throw new Error('args.risk must be "yes" or "no"')
// A per-call effort overrides the effort of the agent file. A convergence round checks only the
// earlier Act-on items, so it runs at medium at each risk. With no effort, the agent file sets it.
const lensEffort = mode === 'converge' ? 'medium' : risk === 'yes' ? 'high' : null

const lenses = args && args.lenses !== undefined ? args.lenses : null
const paths = args && args.paths !== undefined ? args.paths : null
if (lenses && !Array.isArray(lenses)) throw new Error('args.lenses must be a list of lens keys')
if (paths && (!Array.isArray(paths) || !paths.length || target !== 'diff')) throw new Error('args.paths must be a non-empty list of paths, with target "diff"')
// A branch in a worktree has an empty diff in the main checkout, so every git command and file
// read goes to the tree that args.worktree names.
const worktree = (args && args.worktree) || ''
if (worktree && !worktree.startsWith('/')) throw new Error('args.worktree must be an absolute path')
// A worktree has no .scratchpads, so a relative run file (the ledger, a prior verdict, the plan)
// resolves to no file there, and a skeptic that cannot read the ledger cannot uphold a failure.
const runFiles = [ledger, ...prior, ...(target === 'plan' && args && args.scope ? [args.scope] : [])].filter(Boolean)
if (worktree && runFiles.some(f => !String(f).startsWith('/'))) throw new Error('args.ledger, args.prior, and a plan scope must be absolute paths with args.worktree')
// The default plan is the newest run plan. With a worktree, it is in the main checkout.
const newestPlan = worktree
  ? `.scratchpads/runs (newest run)/plan.md in the main checkout (the parent folder of \`git -C ${worktree} rev-parse --path-format=absolute --git-common-dir\`)`
  : '.scratchpads/runs (newest run)/plan.md'
const scope = (args && args.scope) || (target === 'plan' ? newestPlan : 'main')
const git = worktree ? `git -C ${worktree}` : 'git'
const treeText = worktree ? ` The branch is checked out in ${worktree}: read each tracked file there, not in the main checkout.` : ''

// A lens with no gate runs only when args.lenses names it, at each target. A named lens with gates
// runs only at its gates: code-quality at a plan gate would read an empty diff. A lens with
// `named` is not a default lens: the code gate runs the code-review skill in place of code-quality
// (interrogate Step 3).
const ALL_LENSES = [
  { key: 'premortem', agentType: 'premortem', model: 'opus', effort: 'high', gates: ['plan', 'diff'] },
  { key: 'devils-advocate', agentType: 'devils-advocate', model: 'sonnet', effort: 'medium', gates: ['plan', 'diff'] },
  { key: 'architecture', agentType: 'architecture-reviewer', model: 'opus', effort: 'high', gates: ['plan', 'diff'] },
  { key: 'code-quality', agentType: 'code-quality-reviewer', model: 'sonnet', effort: 'medium', gates: ['diff'], named: true },
  { key: 'context-engineering', agentType: 'context-engineering-reviewer', model: 'opus', effort: 'medium', gates: [] },
  { key: 'prompt-engineering', agentType: 'prompt-engineering-reviewer', model: 'sonnet', effort: 'medium', gates: [] },
  { key: 'harness-engineering', agentType: 'harness-engineering-reviewer', model: 'opus', effort: 'medium', gates: [] },
  { key: 'eval-engineering', agentType: 'eval-engineering-reviewer', model: 'opus', effort: 'medium', gates: [] },
  { key: 'compound-engineering', agentType: 'compound-engineering-reviewer', model: 'sonnet', effort: 'medium', gates: [] },
]
const atGate = l => !l.gates.length || l.gates.includes(target)
const LENSES = ALL_LENSES.filter(l => lenses ? lenses.includes(l.key) && atGate(l) : l.gates.includes(target) && !l.named)
const dropped = lenses ? ALL_LENSES.filter(l => lenses.includes(l.key) && !atGate(l)).map(l => l.key) : []
if (dropped.length) log(`Lenses with no ${target} gate, dropped: ${dropped.join(', ')}.`)
const unknown = lenses ? lenses.filter(k => !ALL_LENSES.some(l => l.key === k)) : []
if (unknown.length) log(`Unknown lens keys: ${unknown.join(', ')}.`)
// An empty panel returns no findings, and that looks the same as a clean review.
if (!LENSES.length) throw new Error(`The selection has no lens (lenses: ${JSON.stringify(lenses)}). The panel did not run.`)

const FINDINGS = {
  type: 'object',
  properties: {
    checked: {
      type: 'array',
      items: { type: 'string' },
      description: 'the files you read and the commands you ran for this review',
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['critical', 'warning', 'nit'] },
          title: { type: 'string' },
          weight: { type: 'string', enum: ['demonstrated', 'read', 'enumerated'], description: 'demonstrated: a probe, a mutant, or an exit status shows it; read: seen in code or text; enumerated: a list for a human to judge' },
          location: { type: 'string', description: 'file:line, or plan section' },
          failure: { type: 'string', description: 'concrete trigger, path, and consequence' },
          evidence: { type: 'string' },
          suggestion: { type: 'string' },
          priorItem: { type: 'string', description: 'the earlier Act-on item or fix commit this finding concerns, or "none"' },
        },
        required: ['severity', 'title', 'weight', 'location', 'failure', 'evidence'],
      },
    },
  },
  required: ['checked', 'findings'],
}

const VERDICTS = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          index: { type: 'number' },
          upheld: { type: 'boolean' },
          reason: { type: 'string' },
        },
        required: ['index', 'upheld', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}

const pathArgs = paths ? ` -- ${paths.join(' ')}` : ''
// A whole diff or a whole ledger in one read fills the context: a lens reads the stat first and
// one file per call, and a skeptic reads only the files that its findings name.
const targetText = target === 'plan'
  ? `The target is the plan at ${scope}. Read it and every file it references.${treeText}`
  : `The target is the diff of the current branch against ${scope}: run \`${git} diff --stat ${scope}...HEAD${pathArgs}\` first, then read the diff of one file per call (\`${git} diff ${scope}...HEAD -- <file>\`), and \`${git} diff${pathArgs}\` for uncommitted work. Read the surrounding code, not only the hunks.${treeText}`
const skepticTargetText = target === 'plan'
  ? `The target is the plan at ${scope}. Read the plan, and only the files that a finding names.${treeText}`
  : `The target is the diff of the current branch against ${scope}: read \`${git} diff ${scope}...HEAD -- <file>\` and \`${git} diff -- <file>\` only for the files that a finding names. Read the surrounding code, not only the hunks.${treeText}`

// The script has no shell, so one agent lists the changed files of the diff. A diff with no
// changed file (the main checkout of a branch in a worktree, or a paths scope that matches
// nothing) gives reviewers nothing to read, and their empty result looks like a clean review.
// review-panel.test.sh stubs this step by its label.
let files = []
if (target === 'diff') {
  const scoped = await agent(
    `Run \`${git} diff --name-only ${scope}...HEAD${pathArgs}\` and \`${git} diff --name-only HEAD${pathArgs}\`. Return each file that either command prints, once. Do not modify files.${treeText}`,
    { label: 'scope', phase: 'Review', effort: 'low', schema: { type: 'object', properties: { files: { type: 'array', items: { type: 'string' } } }, required: ['files'] } },
  )
  files = (scoped && Array.isArray(scoped.files)) ? scoped.files : []
  const where = `${paths ? `The paths scope (${paths.join(' ')})` : 'The diff'}${worktree ? ` in ${worktree}` : ''}`
  if (!files.length) throw new Error(`${where} has no changed file against ${scope}. Pass worktree for a branch in a worktree. The panel did not run.`)
  log(`Diff scope: ${files.length} changed files.`)
}

// Without this list, the devil's advocate attacked user requests and accepted tradeoffs,
// and the skeptics refuted every such finding. That gave no signal.
// A settled scope line can be false in the code ("no vertical scroll" while the view scrolled),
// so at the code gate the reviewers check that the diff keeps each line.
const settledCheck = target === 'diff' ? `\nEach settled line is also a claim about the code. Check that the diff keeps it. A line that the code contradicts is a finding, not a settled choice.` : ''
const settledText = settled.length ? `Settled: the user asked for these, or the run already accepted them. Do not attack them without new evidence that they break a requirement:\n${settled.map(s => `- ${s}`).join('\n')}${settledCheck}` : ''
const priorText = prior.length ? `Earlier rounds of this gate wrote these verdicts. Read them first:\n${prior.map(p => `- ${p}`).join('\n')}` : ''
const MODE_TEXT = {
  open: '',
  converge: `Round ${round} of ${maxRounds}: the convergence round. It closes the gate. ${priorText}\nCheck only these two things. (1) Is each earlier "Act on" item fixed, correctly, and consistently with the other fixes? (2) Did a fix introduce a new defect in the text or code that it changed? Do not review areas that no earlier item or fix touched. Each finding must set priorItem to the item or fix it concerns. Exception: report a critical defect (data loss, crash, security) wherever you see it, with priorItem "none".`,
}

// An agent file reloads at the next call, but only in the checkout of the session. When the diff
// of a worktree changes the agent file, when the file is new there, or when another harness runs
// this script, a general agent reads the worktree file as its role, with the model of the role
// table and the effort of the typed call, else of the table (the test holds the table equal to each
// frontmatter). A plan gate has no scope step: it runs a changed agent file of the worktree as the
// copy of the session checkout.
async function typedAgent(role, prompt, opts) {
  const file = `${worktree ? `${worktree}/` : ''}.claude/agents/${role.agentType}.md`
  const fallback = () => agent(`Read ${file}. Act as that agent and follow its rules. Do not modify files.\n\n${prompt}`, { effort: role.effort, ...opts, model: role.model })
  if (worktree && files.includes(`.claude/agents/${role.agentType}.md`)) {
    log(`${opts.label}: the diff changes ${file}. Running a general agent that reads it`)
    return fallback()
  }
  try {
    return await agent(prompt, { ...opts, agentType: role.agentType })
  } catch (error) {
    log(`${opts.label}: typed agent failed (${error && error.message}). Retrying as a general agent that reads ${file}`)
    return fallback()
  }
}

const SKEPTIC = { agentType: 'skeptic', model: 'sonnet', effort: 'medium' }

async function review(lens) {
  const task = `Intent (assume the goal is right, attack the execution):\n> ${intent}\n\n${targetText}\n\n${settledText}\n\n${MODE_TEXT[mode]}\n\nReturn your findings, and in \`checked\` the files you read and the commands you ran. An empty findings list is a valid result. An empty \`checked\` list is not.`
  log(`review:${lens.key}: effort ${lensEffort || `${lens.effort} (agent file)`}`)
  const opts = { label: `review:${lens.key}`, phase: 'Review', schema: FINDINGS, ...(lensEffort ? { effort: lensEffort } : {}) }
  return typedAgent(lens, `Review with your ${lens.key} lens.\n\n${task}`, opts)
}

const results = await pipeline(
  LENSES,
  review,
  (review, lens) => {
    // A reviewer that returned nothing, or no record of what it checked, failed. Count it as
    // missing, not as a clean review: an empty result looks the same as "no findings".
    if (!review || !Array.isArray(review.findings) || !Array.isArray(review.checked) || !review.checked.length) return null
    // In the convergence round, a finding that names no earlier item or fix is out of scope,
    // unless it is critical. Split by the reviewer's own field, not by the skeptic's wording.
    const unscoped = f => mode === 'converge' && f.severity !== 'critical' && (!f.priorItem || /^none$/i.test(f.priorItem.trim()))
    const outOfScope = review.findings.filter(unscoped)
    // A nit goes to the lead as a Consider item with no skeptic: a skeptic agent costs more than
    // the lead's read of a nit.
    const nits = review.findings.filter(f => !unscoped(f) && f.severity === 'nit')
    const findings = review.findings.filter(f => !unscoped(f) && f.severity !== 'nit')
    if (!findings.length) return { lens: lens.key, raised: review.findings.length, survived: [], refuted: [], outOfScope, nits }
    const list = findings.map((f, i) => `${i}. [${f.severity}, ${f.weight}] ${f.title} @ ${f.location}\n   prior item: ${f.priorItem || 'none'}\n   failure: ${f.failure}\n   evidence: ${f.evidence}`).join('\n')
    return typedAgent(
      SKEPTIC,
      `A ${lens.key} reviewer raised the findings below about a ${target}. ${skepticTargetText}${ledger ? ` Grep ${ledger} for the result tokens (failed, fail, flake, survived, NOT VERIFIED, missed unknown) and the words of each finding: a finding whose failure already happened in this run is upheld, even if it looks hypothetical.` : ''}${settledText ? `\n\n${settledText}` : ''}${mode === 'converge' ? `\n\n${priorText}` : ''}\n\nFindings:\n${list}`,
      { label: `verify:${lens.key}`, phase: 'Verify', schema: VERDICTS },
    ).then(v => {
      const upheld = new Map(((v && v.verdicts) || []).map(x => [x.index, x]))
      const judged = findings.map((f, i) => ({ ...f, skeptic: upheld.get(i) }))
      const survived = judged.filter(f => !f.skeptic || f.skeptic.upheld)
      // Keep the refuted findings with the skeptic reason, so the lead can list them under Dismissed.
      const refuted = judged.filter(f => f.skeptic && !f.skeptic.upheld)
      return { lens: lens.key, raised: review.findings.length, survived, refuted, outOfScope, nits }
    })
  },
)

const panel = results.filter(Boolean)
const missing = [...unknown, ...LENSES.filter(l => !panel.some(p => p.lens === l.key)).map(l => l.key)]
if (missing.length) log(`NO RESULT from lenses: ${missing.join(', ')}. The panel is incomplete.`)
log(panel.map(p => `${p.lens}: ${p.survived.length}/${p.raised} survived, ${p.nits.length} nits, ${(p.outOfScope || []).length} out of scope`).join(', '))
const outOfScope = panel.flatMap(p => (p.outOfScope || []).map(f => ({ lens: p.lens, ...f })))
if (outOfScope.length) log(`${outOfScope.length} out-of-scope findings for the backlog.`)
return { target, intent, scope, round, maxRounds, mode, panel, outOfScope, missing }
