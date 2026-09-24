export const meta = {
  name: 'review-panel',
  description: 'Lens review panel (premortem, devils advocate, architecture, code quality) on a plan or diff, with a skeptic check per lens',
  whenToUse: 'Plan gate and code gate of the deliver skill. Args: { target: "plan" | "diff", intent: string, scope: string (plan path, or base ref such as main), round?: number (default 1), maxRounds?: number (default 2 for plan, 3 for diff), prior?: string[] (verdict files of earlier rounds), settled?: string[] (choices the user asked for or the run already accepted; reviewers do not attack them) }. The last round (round >= maxRounds) only checks that earlier fixes converged.',
  phases: [
    { title: 'Review', detail: 'one reviewer agent per lens' },
    { title: 'Verify', detail: 'one skeptic per lens tries to refute its findings' },
  ],
}

const target = args && args.target === 'plan' ? 'plan' : 'diff'
const intent = (args && args.intent) || 'No intent given. Derive it from the plan or the commit messages.'
const scope = (args && args.scope) || (target === 'plan' ? '.scratchpads/runs (newest run)/plan.md' : 'main')
const round = Number(args && args.round) || 1
const maxRounds = Number(args && args.maxRounds) || (target === 'plan' ? 2 : 3)
const prior = (args && Array.isArray(args.prior)) ? args.prior : []
const settled = (args && Array.isArray(args.settled)) ? args.settled : []
// Round 1 reviews openly. A middle round must not re-raise fixed items. The last round checks
// convergence only: an open last round keeps widening the review and never closes the gate.
const mode = round === 1 && !prior.length ? 'open' : round >= maxRounds ? 'converge' : 'followup'
if (mode !== 'open' && !prior.length) log(`Round ${round} has no prior verdicts. Reviewers cannot see what earlier rounds fixed.`)

const LENSES = [
  { key: 'premortem', agentType: 'premortem', model: 'opus', gates: ['plan', 'diff'] },
  { key: 'devils-advocate', agentType: 'devils-advocate', model: 'sonnet', gates: ['plan', 'diff'] },
  { key: 'architecture', agentType: 'architecture-reviewer', model: 'opus', gates: ['plan', 'diff'] },
  { key: 'code-quality', agentType: 'code-quality-reviewer', model: 'sonnet', gates: ['diff'] },
].filter(l => l.gates.includes(target))

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
          location: { type: 'string', description: 'file:line, or plan section' },
          failure: { type: 'string', description: 'concrete trigger, path, and consequence' },
          evidence: { type: 'string' },
          suggestion: { type: 'string' },
          priorItem: { type: 'string', description: 'the earlier Act-on item or fix commit this finding concerns, or "none"' },
        },
        required: ['severity', 'title', 'location', 'failure', 'evidence'],
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

const targetText = target === 'plan'
  ? `The target is the plan at ${scope}. Read it and every file it references.`
  : `The target is the diff of the current branch against ${scope}: run \`git diff ${scope}...HEAD\` and \`git diff\` for uncommitted work. Read the surrounding code, not only the hunks.`

// Without this list, the devil's advocate attacked user requests and accepted tradeoffs,
// and the skeptics refuted every such finding. That gave no signal.
const settledText = settled.length ? `Settled: the user asked for these, or the run already accepted them. Do not attack them without new evidence that they break a requirement:\n${settled.map(s => `- ${s}`).join('\n')}` : ''
const priorText = prior.length ? `Earlier rounds of this gate wrote these verdicts. Read them first:\n${prior.map(p => `- ${p}`).join('\n')}` : ''
const MODE_TEXT = {
  open: '',
  followup: `Round ${round} of ${maxRounds}. ${priorText}\nDo not raise an item that an earlier round already fixed, unless the fix is wrong. Set priorItem on each finding.`,
  converge: `Round ${round} of ${maxRounds}: the convergence round. It closes the gate. ${priorText}\nCheck only these two things. (1) Is each earlier "Act on" item fixed, correctly, and consistently with the other fixes? (2) Did a fix introduce a new defect in the text or code that it changed? Do not review areas that no earlier item or fix touched. Each finding must set priorItem to the item or fix it concerns. Exception: report a critical defect (data loss, crash, security) wherever you see it, with priorItem "none".`,
}

// Agent types load at session start. When the session started before an agent file
// existed, or another harness runs this script, fall back to a general agent that
// reads the same agent file as its role.
async function review(lens) {
  const task = `Intent (assume the goal is right, attack the execution):\n> ${intent}\n\n${targetText}\n\n${settledText}\n\n${MODE_TEXT[mode]}\n\nReturn your findings, and in \`checked\` the files you read and the commands you ran. An empty findings list is a valid result. An empty \`checked\` list is not.`
  const opts = { label: `review:${lens.key}`, phase: 'Review', schema: FINDINGS }
  try {
    return await agent(`Review with your ${lens.key} lens.\n\n${task}`, { ...opts, agentType: lens.agentType })
  } catch (error) {
    log(`${lens.key}: typed agent failed (${error && error.message}). Retrying as a general agent that reads .claude/agents/${lens.agentType}.md`)
    return agent(
      `Read .claude/agents/${lens.agentType}.md. Act as that reviewer and follow its rules. Do not modify files.\n\n${task}`,
      { ...opts, model: lens.model },
    )
  }
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
    const findings = review.findings.filter(f => !unscoped(f))
    if (!findings.length) return { lens: lens.key, raised: review.findings.length, survived: [], refuted: [], outOfScope }
    const list = findings.map((f, i) => `${i}. [${f.severity}] ${f.title} @ ${f.location}\n   prior item: ${f.priorItem || 'none'}\n   failure: ${f.failure}\n   evidence: ${f.evidence}`).join('\n')
    return agent(
      `You are a skeptic. A ${lens.key} reviewer raised the findings below about a ${target}. ${targetText}\n\nFor each finding, try to refute it by reading the actual ${target === 'plan' ? 'plan and code' : 'code'}. A finding is upheld only when the path it describes exists and nothing already handles it. A finding that is only a style preference, or that asks for an abstraction with a single use, is not upheld. A finding that attacks a settled choice without new evidence is not upheld. Do not modify files.${settledText ? `\n\n${settledText}` : ''}${mode === 'converge' ? `\n\n${priorText}` : ''}\n\nFindings:\n${list}`,
      { label: `verify:${lens.key}`, phase: 'Verify', schema: VERDICTS, effort: 'medium' },
    ).then(v => {
      const upheld = new Map(((v && v.verdicts) || []).map(x => [x.index, x]))
      const judged = findings.map((f, i) => ({ ...f, skeptic: upheld.get(i) }))
      const survived = judged.filter(f => !f.skeptic || f.skeptic.upheld)
      // Keep the refuted findings with the skeptic reason, so the lead can list them under Dismissed.
      const refuted = judged.filter(f => f.skeptic && !f.skeptic.upheld)
      return { lens: lens.key, raised: review.findings.length, survived, refuted, outOfScope }
    })
  },
)

const panel = results.filter(Boolean)
const missing = LENSES.filter(l => !panel.some(p => p.lens === l.key)).map(l => l.key)
if (missing.length) log(`NO RESULT from lenses: ${missing.join(', ')}. The panel is incomplete.`)
log(panel.map(p => `${p.lens}: ${p.survived.length}/${p.raised} survived, ${(p.outOfScope || []).length} out of scope`).join(', '))
const outOfScope = panel.flatMap(p => (p.outOfScope || []).map(f => ({ lens: p.lens, ...f })))
if (outOfScope.length) log(`${outOfScope.length} out-of-scope findings for the backlog.`)
return { target, intent, scope, round, maxRounds, mode, panel, outOfScope, missing }
