---
name: domain-modeling
description: Build and sharpen the domain model of the project. Use when you discuss codebase terms, write or edit `CONTEXT.md` (the glossary), or write or edit a decision record in `docs/decisions/`.
---

# Domain modeling

Build and sharpen the domain model of the project while you design. This skill is the active work: challenge terms, invent edge-case scenarios, and write the glossary and the decisions down when they become clear. Use it when you change the model.

## File structure

Most repos have a single context: one `CONTEXT.md` at the root, and the decision records in `docs/decisions/`.

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts. The map points to where each one lives. Each context has its own `CONTEXT.md` and can have its own `docs/decisions/`. The root `docs/decisions/` keeps the system-wide decisions.

Create files lazily: only when you have something to write. If no `CONTEXT.md` exists, create one when the first term is resolved. If no `docs/decisions/` exists, create it when the first decision record is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y. Which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account': do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When you discuss domain relationships, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible. Which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` at once. Do not batch the updates. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

Keep implementation details out of `CONTEXT.md`. It is a glossary and nothing else: not a spec, a scratch pad, or a record of implementation decisions.

### Offer decision records sparingly

Only offer to write a decision record when all three are true:

1. **Hard to reverse**: the cost of changing your mind later is meaningful
2. **Surprising without context**: a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off**: there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the record. Use the format of the existing records in `docs/decisions/` (see `0001-native-swift-stack.md`).
