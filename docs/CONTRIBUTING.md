# Contributing

The code is open to read, fork, and build under the Apache License 2.0. The project takes issues and pull requests only from collaborators.

The project takes no bug reports and no pull requests from other people. A person who got a DMG from the maintainer reports a bug to the maintainer: give the text of **Dirigible > About Dirigible** and the zip of **Help > Report a Problem…** (see [Report a problem](guide.md#report-a-problem)).

To report a security problem, use GitHub private vulnerability reporting, as [SECURITY.md](SECURITY.md) says. Never report it in an issue.

## How the project works

Agents and humans follow the same rules. [`AGENTS.md`](../AGENTS.md) has the commands, the testing rules, and the git rules. [`CODING_STANDARDS.md`](../CODING_STANDARDS.md) has the design rules and the **Safety** rules that a review checks. Every feature goes through the [`deliver` skill](../.claude/skills/deliver/SKILL.md): analyze, plan, review, implement test-first, review, verify, reflect, and land. Decision records are in [`docs/decisions/`](decisions/).

Run `make setup` once per clone. It enables the git hooks. A person who only builds the app does not need it.
