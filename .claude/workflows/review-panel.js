export const meta = {
  name: 'review-panel',
  description: 'Lens review panel (premortem, devils advocate, architecture, code quality) on a plan or diff, with a skeptic check per lens',
  whenToUse: 'Plan gate and code gate of the deliver skill. Args: { target: "plan" | "diff", intent: string, scope: string (plan path, or base ref such as main) }',
  phases: [
    { title: 'Review', detail: 'one reviewer agent per lens' },
    { title: 'Verify', detail: 'one skeptic per lens tries to refute its findings' },
  ],
}

const target = args && args.target === 'plan' ? 'plan' : 'diff'
const intent = (args && args.intent) || 'No intent given. Derive it from the plan or the commit messages.'
const scope = (args && args.scope) || (target === 'plan' ? '.scratchpads/runs (newest run)/plan.md' : 'main')

const LENSES = [
  { key: 'premortem', agentType: 'premortem', gates: ['plan', 'diff'] },
  { key: 'devils-advocate', agentType: 'devils-advocate', gates: ['plan', 'diff'] },
  { key: 'architecture', agentType: 'architecture-reviewer', gates: ['plan', 'diff'] },
  { key: 'code-quality', agentType: 'code-quality-reviewer', gates: ['diff'] },
].filter(l => l.gates.includes(target))

const FINDINGS = {
  type: 'object',
  properties: {
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
        },
        required: ['severity', 'title', 'location', 'failure', 'evidence'],
      },
    },
  },
  required: ['findings'],
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

// Agent types load at session start. When the session started before an agent file
// existed, or another harness runs this script, fall back to a general agent that
// reads the same agent file as its role.
async function review(lens) {
  const task = `Intent (assume the goal is right, attack the execution):\n> ${intent}\n\n${targetText}\n\nReturn your findings. An empty list is a valid result.`
  const opts = { label: `review:${lens.key}`, phase: 'Review', schema: FINDINGS }
  try {
    return await agent(`Review with your ${lens.key} lens.\n\n${task}`, { ...opts, agentType: lens.agentType })
  } catch (error) {
    log(`${lens.agentType} agent type not available, using a general agent with .claude/agents/${lens.agentType}.md`)
    return agent(
      `Read .claude/agents/${lens.agentType}.md. Act as that reviewer and follow its rules. Do not modify files.\n\n${task}`,
      opts,
    )
  }
}

const results = await pipeline(
  LENSES,
  review,
  (review, lens) => {
    const findings = (review && review.findings) || []
    if (!findings.length) return { lens: lens.key, raised: 0, survived: [] }
    const list = findings.map((f, i) => `${i}. [${f.severity}] ${f.title} @ ${f.location}\n   failure: ${f.failure}\n   evidence: ${f.evidence}`).join('\n')
    return agent(
      `You are a skeptic. A ${lens.key} reviewer raised the findings below about a ${target}. ${targetText}\n\nFor each finding, try to refute it by reading the actual ${target === 'plan' ? 'plan and code' : 'code'}. A finding is upheld only when the path it describes exists and nothing already handles it. A finding that is only a style preference, or that asks for an abstraction with a single use, is not upheld. Do not modify files.\n\nFindings:\n${list}`,
      { label: `verify:${lens.key}`, phase: 'Verify', schema: VERDICTS, effort: 'medium' },
    ).then(v => {
      const upheld = new Map(((v && v.verdicts) || []).map(x => [x.index, x]))
      const survived = findings
        .map((f, i) => ({ ...f, skeptic: upheld.get(i) }))
        .filter(f => !f.skeptic || f.skeptic.upheld)
      return { lens: lens.key, raised: findings.length, survived }
    })
  },
)

const panel = results.filter(Boolean)
const missing = LENSES.filter(l => !panel.some(p => p.lens === l.key)).map(l => l.key)
if (missing.length) log(`NO RESULT from lenses: ${missing.join(', ')}. The panel is incomplete.`)
log(panel.map(p => `${p.lens}: ${p.survived.length}/${p.raised} survived`).join(', '))
return { target, intent, scope, panel, missing }
