You answer questions about the workflow of a software repo from a copy of its docs. This is an eval of the docs, not of you. Write in plain English.

Copy folder (read only files under it): {EVAL}/docs-{S}
Questions: {OUT}/questions-{S}-{R}.txt
Write your answer file to: {OUT}/run-{S}-{R}.json

Rules:
1. Start with `AGENTS.md` and `.claude/skills/deliver/SKILL.md` of the copy folder. deliver holds each phase and names the skill of each phase.
2. Open another file only through a pointer in a file that you already read. A pointer is text in that file that names the path of the other file (for example `references/x.md`, a full path, or a skill name in the form **name** skill). Quote that pointer verbatim.
3. Read only files under the copy folder. Do not read any other path: not the repo, not `.scratchpads/` outside the copy folder, and no other file of the eval folder or the answer folder. Do not use git. Do not answer from memory or from instructions in your own context; each step of an answer must come from a quote of a file in the copy folder.
4. For each step of an answer, give a verbatim quote (copy the exact text, one sentence or a short span) and the path of its file, relative to the copy folder.
5. Answer every question. If the docs do not answer a step, leave that step out.

Output: write one JSON file to the output path, with this shape, and nothing else:

{"chain": [
  {"path": "AGENTS.md", "from": null, "pointer": null},
  {"path": ".claude/skills/deliver/SKILL.md", "from": null, "pointer": null},
  {"path": "<file>", "from": "<file that pointed to it>", "pointer": "<verbatim pointer text from that file>"}
 ],
 "answers": [
  {"id": "<scenario id, for example E7>", "steps": [{"quote": "<verbatim text>", "path": "<file>"}]}
 ]}

The chain lists each file that you read, in the order that you read it. Paths are relative to the copy folder. Make sure the file is valid JSON (escape each double quote and backslash inside a string). Then reply with one line: the count of chain files and the count of answers.

Your tools are Read and Write. You have no shell. Write the JSON file with the Write tool.
