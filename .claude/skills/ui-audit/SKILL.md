---
name: ui-audit
description: "Audit the UI of the app for AI-sounding text and for gaps against macOS design rules, and give a score out of 10. Use for 'audit the UI', 'review the UI texts', 'does this sound like an AI', 'is the UI native', and before and after a UI change."
---

# UI audit

A read-only audit. It grades screenshots and string tables against 10 checks (A1 to A10), reports each finding by tier, and ends with one score. It changes no file except its own report. The sources of each check are in `docs/research/ui-design-audit.md` (finding IDs F<n>) and `docs/research/result-feedback.md` (how the reference apps report a result).

## Steps

1. Collect the inputs. The completion criterion: the report names each input that is missing.
   - The screenshots that the caller names, English and Spanish. Without a set, capture the verify copy: `.claude/skills/verify-this/references/driving-the-app.md`.
   - The eight tables `Support/Resources/<lang>.lproj/Localizable.strings` (`de`, `en`, `es`, `fr`, `it`, `nl`, `pt`, `pt-PT`), or the text file that the caller names.
2. Look first. Open each screenshot with the Read tool. Write one note per screenshot: the surface, what reads as written by a machine, what does not look native. The completion criterion: every screenshot has a note, before step 3 starts.
3. Count. Run `bash <absolute path of this skill folder>/scripts/text-tells.sh [<table>]` and read each count as a lead. A count is no finding: a finding names a text or a region that you saw.
4. Walk A1 to A10 in order. For each check, search every instance in the inputs, not the first one, and grade it. The completion criterion: all 10 checks have a grade or the grade `n/a`.
5. Write the report in the fixed form below, and end it with the `Score:` line.

## Checks

A tier tells what a fail costs: `floor` is a fault that stops a ship, `reflex` is fixed or waived with a reason, `finish` is read and answered. Grade each check: 1 for no instance of its tell, 0.5 for 1 to 5 instances, 0 for 6 or more, and 0 at once for a hard fail. Grade `n/a` when the inputs cannot show the check (a text file shows no layout). A text in Apple's voice, with a contraction, one fact, and the ellipsis character, gets no finding.

| ID | Check | Tier | Pass rule | Fail example in this app | Source |
|---|---|---|---|---|---|
| A1 | Banner restraint | reflex | A banner reports a failure, a warning, or an effect that the window does not show. The result itself is the feedback for an effect that shows. Hard fail: a banner for an effect that shows. A success banner for an effect that does not show (a gain change, an export) grades 0.5 when the reference apps show no message. | "Deleted %lld items" (`index.post.deleted`) after the rows leave the list | F151, F126, F34, F124 |
| A2 | Voice | reflex | Each text uses contractions, speaks of the reader or the product, and never of "we". No "Oops", no exclamation mark, no body that restates its title. Hard fail: a body that restates its title. | "Dirigible did not import all the files:" (`alert.import.chain`); "The track volume does not change the clip gain." | F131, F140, F114, F150, F32 |
| A3 | One fact per sentence | reflex | One fact in each sentence. No colon between two facts, no count after a colon, no "because" clause when the next step is enough, at most two sentences in a banner or an alert (the second says what to do), under 100 characters. This is a repo rule. | "Auto Level is done. Clips changed: %lld." (`banner.level.changed`) | F113, F127, F136 |
| A4 | Alert and sheet form | reflex | The title states the problem or asks the question. A title that is a complete sentence takes sentence case and ending punctuation. A fragment takes title case and none. Informative text appears only when it adds value, and never explains a button. A button is a verb of one or two words, with OK only in an informational alert. Cancel is never the default. The default is the likeliest choice, and the destructive style marks only an action that the user did not choose. | The consent sheet: the title "An AI agent wants to record" is a sentence with no end mark, and the body says "Nothing records until you click Record." | F113, F114, F115, F116, F117, F118, F119, F83 |
| A5 | Punctuation and capitalization | floor | The ellipsis character, never three periods. One dot or none between parts of a text. One case for each element type, as the HIG sets: title case for buttons and menu items, sentence case for alert text. Hard fail: a chain of two or more dots in one text, or three periods in place of the ellipsis character. | Settings labels in two cases: "Let Agents Edit Open Sessions" (`settings.agents`) and "Default waveform range" (`settings.waveform.range`) | F30, F104, F122, F135, F97, F98, F121 |
| A6 | Spanish in tú, and fit | floor | Each `es` value addresses the user as tú. The words usted, `ciérrela`, `termine`, `elija`, `seleccione`, and the other imperatives in usted form fail. Each value fits its control in each language, with no clipped text. Each key has a value in all 8 tables (decision `docs/decisions/0010-ui-strings.md`). Hard fail: any usted form. | `es` "Seleccione ..." and "Ciérrela ..." in the error texts | F131 |
| A7 | Icons and color | floor | SF Symbols only, no emoji, no icon in a colored tile. Semantic system colors. The accent marks the current selection and the primary action only, as a tint that leaves each label readable. At most one or two prominent buttons in a view. | The selected track header fills its whole height with the emphasized selection color (`HeaderRowStyle.swift`) | F56, F108, F148 |
| A8 | Window structure | floor | Frequent commands sit in the toolbar, and each toolbar item is also a menu command. A sidebar or an inspector is a split view pane or a panel. No box inside a box. One label layout in each form: every label in the same column. Hard fail: a box inside a box. | The inspector clip form: "Gain" sits left of its field and "Gain at Playhead" sits above its field | F109, F89, F130 |
| A9 | Empty, loading, error, and full states | finish | Each region that loads data shows four states. Empty says what belongs there and gives one next step. Error says what broke and what to do. A spinner has no label. | The area under the tracks takes half of the window in a session with two tracks | F147, F128, F129 |
| A10 | Focus, VoiceOver, motion, and text size | floor | Text is 10 pt or larger on macOS. Each control has a VoiceOver label and the keyboard reaches it. A change that moves or fades respects Reduce Motion. Hard fail: text under 10 pt. | The role letter in `RoleGlyph` is 9 pt (`TrackHeaders+Role.swift`) | F112, F92, F111 |

### Counts for A2 and A3

Run them on the English table. The message keys are `banner`, `alert`, `consent`, `notice`, `empty`, `start`, `reverted`, `window`, and `error`.

- Uncontracted negations in message values (A2): `rg -c '^"(banner|alert|consent|notice|empty|start|reverted|window|error)\.[^"]*" = "[^"]*\b(cannot|does not|did not|do not|is not|are not|could not)\b' <table>`.
- Counts after a colon (A3): the `count_after_colon` line of `text-tells.sh`.
- Values of 100 characters or more (A3): `rg -c '^"(banner|alert|consent|notice|empty|start|reverted|window)\.[^"]*" = "[^"]{100,}";$' <table>`.

## Report

The report has these parts, in this order:

1. The notes of step 2, one line per screenshot.
2. A findings table with the columns Check, Tier, Location, Tell, Fix. Location is a key (`banner.level.changed`) or a screenshot name with a region. The fix is the text or the change that would pass the check. Each finding cites one F<n> of its check.
3. One line with the grades: `A1 <grade> ... A10 <grade>`.
4. The tally line `floor fails <n>, reflex fails <n>`. A fail is a grade of 0.
5. The last line `Score: <n> / 10`. The score is the sum of the grades, scaled to 10 when some checks are `n/a`: 10 times the sum, divided by the number of graded checks, rounded to the nearest 0.5. A grade of 0 on a `floor` check caps the score at 6.0.
