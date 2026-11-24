# UI design audit: Hallmark and Apple HIG (checked)

Date: 2026-11-24

This file checks a draft (a local note, not in the repo) claim by claim against primary sources. The draft covers the Hallmark design skill, the Apple Human Interface Guidelines (HIG), and a 10-check rubric for a macOS UI audit skill. Each finding has a number (F1, F2, ...). Each row has one verdict: VERIFIED, CHANGED, NOT FOUND, INCONCLUSIVE, or INFERENCE. "Draft Lnn" means a line of the draft. In quotes, curly marks are written as ASCII, and a dash is written as a hyphen. Apple pages come from the JSON form of each HIG page. The Apple Style Guide comes from its HTML pages. The Hallmark text comes from commit `04977e15f3dfd6ee4b74c887dac3eb52665d6c92`. The HIG JSON has no per-page platform tag. This file reads the platform from section headings ("## macOS") and from the text. Where a page says "No additional considerations for ... macOS", the general text applies to macOS.

## Verdict counts

| Verdict | Count |
| --- | --- |
| VERIFIED | 89 |
| CHANGED | 48 |
| NOT FOUND | 9 |
| INCONCLUSIVE | 1 |
| INFERENCE | 6 |

Total: 153 findings (F1 to F153). Rows F1 to F111 check the draft. Rows F112 to F153 are added facts. In those rows, the verdict shows whether the source has the text.

## Hallmark

Source for this section: the Hallmark repo at the commit above, files under `skills/hallmark/`. Short name: `gates.md` is `references/gates.md`. The class letters mean: M is a static check, R is a render check, J is a judged check, and a slash means either half.

### Repo, verbs, and flow

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F1 | Hallmark is v2.0.0, made by Nutlope and Together AI (L9) | CHANGED | `SKILL.md` front matter says `version: 2.0.0`. The README says "Made by Together AI." Nutlope is the GitHub owner of the repo. The default branch is `main`. |
| F2 | Install with `npx skills add nutlope/hallmark` (L13) | VERIFIED | README and site: `npx skills add nutlope/hallmark -g`. The `-g` flag installs for every project. |
| F3 | Purpose quote from `SKILL.md` (L11) | VERIFIED | "Makes the UIs a coding assistant generates look made, not generated: a hard floor against the defaults every model was trained into, a dealt direction so consecutive builds do not converge, one idea per screen." |
| F4 | The skill exposes four verbs: `build`, `audit`, `redesign`, `study` (L17-22) | CHANGED | `SKILL.md` names two verbs: "`redesign <target>` ... and `audit <target>` (a report)". Build is the default flow. The front matter hint is `<prompt> \| redesign <path> \| audit <path>`. |
| F5 | `study <url\|image>` extracts type and color from a reference (L22) | NOT FOUND | No file in the commit has a `study` verb. `rg -i study` finds nothing in the Markdown files. |
| F6 | `build` deals a theme from "50+ catalog files" (L19) | CHANGED | The README says "fifty themes". The `themes/` folder has 50 theme `.md` files, plus `index.json` and pictures. |
| F7 | Three scopes: page (default), component, app screen (L24-27) | VERIFIED | `flow.md` has "Component scope" and "App screens". `sloplint.mjs` accepts `--scope page\|component\|app`. |
| F8 | Component scope lists banner and snackbar, skips page macrostructures, needs an 8-state preview (L26) | VERIFIED | `flow.md`: the signal list has "banner, snackbar". "Skips: macrostructure, nav and footer, hero, imagery". The preview shows "every state stacked and labelled". |
| F9 | Pre-flight caches to `.hallmark/preflight.json` and classes each route as page, component, or app screen (L33) | CHANGED | The cache path is correct (`flow.md`). `redesign.md` Before step 1 says "whether each is a page or an app screen". It does not list "component". |
| F10 | The sloplint command, flags, `.hallmark/before.txt`, `.hallmark/before/`, `.hallmark/before.json` (L34) | VERIFIED | `redesign.md` Before step 2 gives the same command and paths. |
| F11 | Headless Chrome through `puppeteer-core`, viewports 320 to 1920 (L34) | VERIFIED | `flow.md` render tier: "needs Node 18 or later, `puppeteer-core` ... and Chrome". `sloplint-render.mjs` has `WIDTHS = [320, 375, 414, 768, 1024, 1280, 1440, 1920]`. |
| F12 | Audit loads `gates.md` sections 1, 4, 5 and stops without editing (L35-37) | VERIFIED | `redesign.md`: "`audit <target>` stops here. It loads `gates.md` § 1, § 4 and § 5, walks the judged gates from the screenshots, and reports the findings by tier with `file:line`, the read, the lightest depth that settles them and what only a deeper one would. It changes none of the project's files." |
| F13 | The four-line read quote (L37) | VERIFIED | `redesign.md`: "give the read in four lines: what the page is for (the audience, the one action); what works and stays (at least one thing); what reads as generated (the worst tells, by gate); what is broken." |

### Tiers, grades, and scoring

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F14 | Four tiers: Floor, Reflex, Finish, Ledger (L43-47) | VERIFIED | `gates.md` § 1 lists exactly these four. |
| F15 | Floor house rules are gates 54, 58, 63, 67 (L44) | VERIFIED | `gates.md` § 1: "54 (the eyebrow), 58 (the screen budget), 63 (template punctuation) and 67 (the tracked-caps label), and no others." |
| F16 | A Reflex waiver needs 24 characters and guard evidence. Over three waivers warns (L45) | VERIFIED | `gates.md` § 2: a reason "under 24 characters, boilerplate, or reused word for word ... is rejected". § 1: "past three waivers sloplint notes a house style". |
| F17 | Finish checks run F1 through F20 (L46) | CHANGED | `gates.md` § 5 lists F1 through F26. |
| F18 | Ledger is gate 32, reports as NOTE (L47) | VERIFIED | `gates.md` § 1: "Ledger. Bookkeeping about repetition (32). Reports at `NOTE`, never counts toward the verdict." |
| F19 | Six grades: FAIL, REFLEX, WAIVED, WARN, ANSWERED, NOTE (L48-54) | VERIFIED | `gates.md` § 1 lists these six and adds `DISMISSED` as a report form of a dismissed WARN. |
| F20 | Classes M, M/R, R, R/J, J (L55) | VERIFIED | `gates.md` § 1 defines these classes. |
| F21 | The audit punch list has severity `Critical`, `Major`, `Minor` (L56) | NOT FOUND | No source file has these three words as severity. The audit reports "by tier". |
| F22 | The tally is `Floor 0 FAIL · Reflex N (M waived) · finish-review: [status]` and belongs to the audit (L56) | CHANGED | This string is the last row of a build Picks block (`SKILL.md` Step 7.5): "`Floor 0 FAIL · Reflex 2 (1 waived: 47b) · finish-review: subagent, 3 resolved`". The audit does not print it. `sloplint.mjs` prints a tally like `2 FAIL, 1 REFLEX, 3 WARN, 1 WAIVED`. |
| F23 | Six critique axes: Philosophy, Hierarchy, Execution, Specificity, Restraint, Variety; scores 1 to 5; under 3 forces a revision (L57-64) | VERIFIED | `gates.md` § 3: "score the planned page 1 to 5 on six axes; anything under 3 triggers a revision first." The table has the same six names. |
| F24 | The axis quotes join two descriptions, for example "has a tone, has an argument a reader could disagree with" (L59-64) | CHANGED | The table has two anchors per axis. Score 3 is "has a tone". Score 5 is "has an argument a reader could disagree with". The draft merges them. |
| F25 | The critique runs "before finishing a build or redesign" (L58) | CHANGED | It runs before the sweep, on the planned page. A check stamp has "no critique line (nothing was planned)" (`flow.md`). The six-axis score does not apply to an audit of existing screens. |

### Gates: copy and text

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F26 | Gate 19, Floor, M: buzzword list and stock openers (L71) | VERIFIED | The word list matches `gates.md` row 19. The row also bans "em or en dashes", placeholder names, and a stock second action ("Learn more, Get started, Book a demo"). |
| F27 | Opener example "Built for modern teams" (L71) | CHANGED | The row says `"Built for the modern team"`. |
| F28 | Gate 46a, Floor, M, with the `SKILL.md` quote (L72-73) | VERIFIED | `SKILL.md` Floor item 8: "Never an invented metric, testimonial, logo wall or case-study count. (46a)" |
| F29 | Gate 61, Floor, M, template placeholder copy, with a `SKILL.md` quote (L74-75) | NOT FOUND | `gates.md` § 1: "Retired numbers stay retired: 5, 13, 14, 21, 31, 35, 36, 43, 45, 51, 52, 57, 60 and 61". The quote is not in `SKILL.md`. The phrases "Fast and reliable" and "Built for scale" are in no file. "Lorem ipsum" is a gate 19 tell in `sloplint.mjs`. |
| F30 | Gate 63, Floor, M/J, with two quotes (L76-78) | VERIFIED | Both quotes match `SKILL.md` item 10 and `gates.md` § 5. Legal uses: "One dot in a byline, a marquee's separator and a dot that conveys live state are legal." The script fires from two dots. |
| F31 | Gate 66, Reflex, M/J: rotated labels, version pills, mono-caps strips, caption filler (L80) | VERIFIED | `gates.md` row 66. It also lists "scroll cues", "a `BETA` pill in the hero", and "a `01 / 4` count on tiles". |
| F32 | Gate 69, Reflex, M/J: the same fact in four or more sections, or "a banner body that merely restates its heading" (L81) | CHANGED | Row 69: one fact "printed in four or more sections ..., or a section's last line restating its heading". The words "banner body" are not in the source. |
| F33 | F1 and F2 are Finish checks, class M (L82-84) | VERIFIED | `gates.md` § 5: "F1 straight quotes in prose · F2 `...` for an ellipsis". The file gives no class for F-checks. `sloplint.mjs` reports both as WARN. |

### Gates: toasts, banners, states

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F34 | Gate 16 is Reflex, class R (L86) | CHANGED | Row 16: tier Reflex, class J. "A celebratory toast for an effect the user already sees". Fix: "silent success". |
| F35 | The gate 16 quote is in `gates.md` section 4 (L87) | CHANGED | The quote is in § 5, "Judged clauses": "16, toasts. If the effect is visible, no toast. Toasts are for failures and invisible effects." The § 4 row is the table row above. |
| F36 | Gate 56, Floor, M/R, two sticky `top: 0` bars (L89) | VERIFIED | Row 56. |
| F37 | Gate 70, Floor, M/J, with examples "Sent", "Saved", "Done" (L92) | CHANGED | Tier and class are correct. The row lists "Sent", "Reserved", "You're on the list", "Thanks". "Saved" and "Done" are not listed. |
| F38 | Gate 68 is Reflex, R/J (L93) | CHANGED | Row 68: Reflex, class M. Gate 81: Reflex, class R (correct in the draft). |
| F39 | Gate 81 quote (L94) | CHANGED | The draft joins the tell cell and the fix cell. Tell: "showing nothing but its wash: no image, video or built sample". Fix: "the user's image, a library photograph (`theme.mjs photos`) or the product at full fidelity". |
| F40 | Eight states quote from `flow.md` Component scope (L96) | VERIFIED | `flow.md`: "every interactive component ships all eight states (default, hover, `:focus-visible`, `:active`, disabled, loading, error, success)". |

### Gates: layout, type, color, icons, motion

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F41 | Gates 54 and 67, Floor, M, with the `SKILL.md` quote (L99-100) | VERIFIED | `SKILL.md` item 9 matches exactly. |
| F42 | Letter-spacing threshold "0.05em+" (L101) | CHANGED | Row 67: "letter-spaced past 0.03em". Row 67 also bans any text at "15px or under set uppercase or in small caps". The draft contradicts itself: Check 5 says 0.03em. |
| F43 | Gate 38i, Floor, M, with quote (L102-103) | VERIFIED | `SKILL.md` item 3. |
| F44 | Gate 64, Reflex, M, with quote (L104-105) | VERIFIED | Row 64 matches. The row ends with a guard: "the theme's material is mono, or the text is code". |
| F45 | Gate 39 bans nested cards and carries the quote "Never cards inside cards, interactive elements nested inside anchors, or icons inside standalone empty shapes. (39, 44e, 58)" (L106-107) | NOT FOUND | The quote is not in any file. Nested cards are gate 4, Floor, M: "A card inside a card". `SKILL.md` item 11 has "a card inside a card (2a, 4, 30a, 47a)". Gate 39 is input states (39a Floor) and control height (39b Reflex). Gate 44e does not exist. |
| F46 | Gate 40 / 47a, Floor, M, fake window chrome, with a `SKILL.md` quote (L108-109) | CHANGED | Gate 40 is contrast (Floor, M/R). Gate 47a is Floor, M: "A hand-drawn browser bar (traffic lights, URL pill) or OS window title bar". The quoted sentence is not in `SKILL.md`. Item 11 has "a hand-drawn browser or OS window". |
| F47 | Gates 71, 72, 73 tiers (L111-113) | VERIFIED | 71 Reflex R, 72 Reflex R, 73 Floor R. |
| F48 | Gate 75 is Floor, M/R (L114) | CHANGED | Row 75: Reflex, class R. The quote is exact: "Text that strains: running text under 12px, functional text under 11px, multi-line prose leaded under 1.3". The unit is px, not pt. |
| F49 | "3-Feature Card Grid" quote from `references/structure.md` (L115-116) | NOT FOUND | The repo has no `structure.md`. The quoted text is in no file. Gate 3 (Reflex, M/R) says: "Card tells: three equal columns of icon-above-heading tiles, an icon in a rounded tile above a heading, a thick coloured side stripe on a card". |
| F50 | F4, F6, F7, F12, F15 quote (L117-118) | VERIFIED | Text matches `gates.md` § 5. F6 covers "display-size figures" only. F15 is skipped in app scope (F60). |
| F51 | Gate 48, Floor, M, with quote (L121-122) | VERIFIED | `SKILL.md` item 1. |
| F52 | Gate 2a, Floor, M, with two quotes (L123-125) | CHANGED | The 2a row is correct. The `SKILL.md` quote "Never a floating blur background, glassmorphism panel, or violet-to-cyan gradient. (36, 42, 47)" is NOT FOUND. Item 11 has "a purple-to-blue gradient". Gate 36 is retired. Gate 42 is the AI nav and footer (Reflex, M). Glow and blur is gate 29 (Reflex, M/J). |
| F53 | Gates 3a, 3b, 41 ban pure black on white and button labels within 5% of the fill (L126) | CHANGED | Gates 3a and 3b do not exist. Pure black and white are gate 7a (Floor, M) and 7b (Reflex, M). Gate 41 (Floor, M/R): "Button text within 5% L and 0.05 chroma of its fill". |
| F54 | Gate 74, Reflex, M, stock framework swatches (L127) | VERIFIED | Row 74. |
| F55 | Icon quote from `imagery.md` section 8 (L131) | VERIFIED | The quote matches with the ellipses the draft marks. |
| F56 | Gate 30a Floor M, F5, gate 33 Floor M (L130-133) | VERIFIED | Rows 30a and 33, and F5 "an icon in a coloured coin". Gate 3 (Reflex, M/R) also bans "an icon in a rounded tile above a heading". |
| F57 | Gate 10a quote (L136-137) | VERIFIED | `SKILL.md` item 2. |
| F58 | Gates 15 and 26a, Floor, M, with quote (L138-139) | CHANGED | Gate 15 is Floor, M. Gate 26a is Floor, M/R. The quote matches `SKILL.md` item 6 "(26a, 15)". |
| F59 | Gates 27 and 62, Floor, M, with quote (L140-141) | VERIFIED | `SKILL.md` item 7. |

### Scope rules for an app screen

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F60 | The `flow.md` "App screens" quote and the skip list "(1, 6, 8, 9, 32, 42, 44, 46b, 58, 59, 66, 68, 77 to 79 and 81 to 83, and F8, F15 and F20)" (L149) | CHANGED | `flow.md`: "(1, 6, 8, 9, 32, 42, 44, 46b, 58, 59, 66, 68, 77 to 79, 81 to 83 and 85, and F8, F15 and F20)". Gate 85 is missing from the draft. `APP_SKIP` in `sloplint.mjs` matches `flow.md`. |
| F61 | `--scope app` "reads control heights on the app range" (L149) | VERIFIED | Same sentence in `flow.md`. See F146 for the numbers. |
| F62 | Gate 1 bans a system font as the display face, and app scope skips it (L175) | VERIFIED | Row 1: "Inter, Roboto, Open Sans, Poppins, Lato or a system face as the display". `flow.md` app scope: "a familiar sans or a system face is allowed here". |
| F63 | App scope skips gates 6, 8, 9, 32, 44, 58, 59 (L178-179) | VERIFIED | All are in the skip list. |
| F64 | CSS mechanics gates 10a, 34, 50, 53, 62, F3, F10 are web only (L180-181) | VERIFIED | Each gate describes CSS or DOM behavior. App scope does not skip them. They bind on a web app screen. They do not apply to AppKit or SwiftUI. |
| F65 | Gates 76 and 81 (stock photos) do not transfer (L182-183) | VERIFIED | Gate 76 is a broken or uncredited image (Floor, M/R). App scope skips 81 but not 76. Neither applies to a native audio app without photos. |
| F66 | Rubric Check 9 cites gates 68 and 81, and the rubric lists F15 (L340, L118) | CHANGED | `--scope app` skips 68, 81, and F15. A macOS audit is an app-scope audit. These gates do not apply. Use the four-state rule in F147. |

### Draft inferences on Hallmark transfer (Section 2)

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F67 | Inference: SF Symbols is the macOS icon system. Emoji and colored coins look like a web template (L162) | INFERENCE | The HIG SF Symbols page says a symbol can appear "wherever interface icons can appear". No HIG text names emoji. No source contradicts it. |
| F68 | Inference: nested rounded boxes "three levels deep" fight split-view hierarchy (L164) | INFERENCE | Gate 4 bans a card inside a card: two levels, not three. The HIG split-views text does not mention cards. No contradiction. |
| F69 | Inference: "at most one filled primary button" matches the macOS default button (L166) | INFERENCE | Contradicted in part. HIG Buttons: "Keep the number of prominent buttons to one or two per view." Hallmark F4 flags "two filled buttons side by side". The HIG allows two. |
| F70 | Inference: `:root` tokens map to semantic system colors; focus ring instant; Reduce Motion respected (L168) | INFERENCE | Hallmark has the token and focus rules (gates 48, 15, 26a, 27). The color mapping is in neither source. HIG Accessibility has the Reduce Motion rule (F92). |
| F71 | Monospace only for data, and F6 keeps counters from jitter (L159-160) | CHANGED | Gate 64 allows mono for "a figure or a measurement". F6 covers "display-size figures". It does not cover a small timecode label. |
| F72 | Controls need "default, hover where applicable, focused, pressed, disabled, loading, error, populated" (L170) | CHANGED | Hallmark's eight states end with "success", not "populated". Gate 26b (Reflex, M) flags a missing `:active` or `:disabled`. |
| F73 | Hallmark ships a 0 to 10 score and a Floor cap at 5 (L281) | INFERENCE | The text says "Inference". Hallmark has no numeric score. A Floor finding is a `FAIL` and "nothing ships". See F142. |

## Apple HIG for macOS

Source: `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`. The draft says "All quotes below come directly from" the HIG. Many are close paraphrases.

### Alerts, feedback, notifications

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F74 | "An alert gives people critical information they need right away." (L195) | VERIFIED | `alerts`, page abstract. |
| F75 | "Use alerts sparingly ... only critical - and ideally actionable - information." (L196) | CHANGED | `alerts`: "Use alerts sparingly. Alerts give people important information, but they interrupt the current task to do so. Encourage people to pay attention to your alerts by making certain that each one offers only essential information and useful actions." |
| F76 | "Avoid using an alert merely to provide information. People appreciate being informed, but ..." (L197) | CHANGED | `alerts`: "Avoid using an alert merely to provide information. People don't appreciate an interruption from an alert that's informative, but not actionable. If you need to provide only information, prefer finding an alternative way to communicate it within the relevant context." |
| F77 | The words "critical - and ideally actionable" come from the Alerts page (L196) | CHANGED | They are on `feedback`: "Use alerts to deliver critical - and ideally actionable - information." |
| F78 | Feedback: "Consider integrating status feedback into your interface ..." (L199) | VERIFIED | `feedback`, exact. Its Mail example names iOS and iPadOS. The page says: "No additional considerations for iOS, iPadOS, macOS, tvOS, or visionOS." |
| F79 | Feedback: "Make sure all feedback is accessible ..." (L200) | VERIFIED | `feedback`, exact. |
| F80 | Notifications quotes: concise; alert not notification for errors; no repeats; no task orders (L202-205) | VERIFIED | `notifications`, all four exact. |
| F81 | "Build trust by accurately representing the urgency of each notification." (L206) | VERIFIED | `managing-notifications`, exact. |
| F82 | Alert title is "a short, descriptive single-line title" and avoids "Error" or "Warning" (L209) | CHANGED | `alerts`: "Write a title that clearly and succinctly describes the situation ... avoid overly long titles that wrap to more than two lines." Bad examples: "Error" and "Error 329347 occurred". "Warning" is not named. |
| F83 | Alert buttons: always a verb, never Yes or No; default is "the safest or most likely action"; destructive role for irreversible actions; always a Cancel (L210) | CHANGED | `alerts`: "Prefer verbs and verb phrases ... In informational alerts only, you can use "OK" for acceptance, avoiding "Yes" and "No."" The default is the button "people are most likely to choose". Destructive style is for an action "people didn't deliberately choose". Cancel is required "If there's a destructive action". |

### Toolbars, sidebars, split views, inspectors

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F84 | Toolbar abstract: "provides convenient access to frequently used commands and controls that perform actions relevant to the current view." (L215) | CHANGED | `toolbars` abstract: "A toolbar provides convenient access to frequently used commands, controls, navigation, and search." |
| F85 | "Choose items deliberately to avoid overcrowding. People need to be able to distinguish and activate each item ..." (L217) | VERIFIED | `toolbars`, exact. |
| F86 | "Make the meaning of each control clear. Don't make people guess ..." (L218) | CHANGED | `toolbars`: "Make sure the meaning of each control is clear. Don't make people guess or experiment to figure out what a toolbar item does. Prefer simple, recognizable symbols for items instead of text, except for actions like edit that aren't well-represented by symbols." |
| F87 | Overflow quote "Accommodate variable view widths ..." (L219) | CHANGED | The sentences are in two paragraphs. "To accommodate variable view widths, define which items move to the overflow menu as the toolbar becomes narrower." Later: "The system automatically adds an overflow menu in macOS or iPadOS when items no longer fit. Don't add an overflow menu manually, and avoid layouts that cause toolbar items to overflow by default." The content is correct. |
| F88 | Customize the toolbar in iPadOS and macOS (L220) | VERIFIED | `toolbars`: "In iPadOS and macOS apps, consider letting people customize the toolbar to include their most common items." |
| F89 | Sidebar quotes: disclosure, familiar symbols, hide, customize (L225-228); split views (L230-231); inspector (L233) | VERIFIED | `sidebars`, `split-views`, `panels`: all exact. `panels`: "Depending on the layout of your app, you might also consider using a split view pane to present an inspector." `toolbars`: the trailing edge holds "buttons that open nearby inspectors". The draft's remark on a trailing toggle and a floating panel is supported. |

### Loading, launching, progress, accessibility

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F90 | Section D quotes on loading and launching (L239, L241) | VERIFIED | `loading` and `launching`, exact. |
| F91 | Progress quotes: determinate, accuracy, moving, no circular-to-bar switch, description, consistent location, Cancel (L248-256) | VERIFIED | `progress-indicators`, all exact. |
| F92 | Draft cites Feedback and Accessibility for focus, Reduce Motion, VoiceOver (L346) | CHANGED | `feedback` does not cover these. `accessibility`: "Let people use the keyboard alone to navigate and interact with your app." Also: when Reduce Motion is on, "ensure your app or game responds by reducing automatic and repetitive animations". |
| F93 | Inference: empty content view needs a headline and one action (L242-243) | INFERENCE | `writing` supports it: "Provide clear next steps on any blank screens." The `searching` page has no empty-state text. `ContentUnavailableView` is an API, not a HIG page. No contradiction. |

### Writing, capitalization, menus, buttons

| ID | Draft claim | Verdict | Correct text or note |
| --- | --- | --- | --- |
| F94 | Writing: "Consider each screen's purpose ...", "Format your text ...", "Be action oriented ..." (L261-263) | VERIFIED | `writing`, exact. |
| F95 | "Determine your app's voice. Think about who you are talking to and the vocabulary they expect..." (L264) | CHANGED | `writing`: "Think about who you're talking to, so you can figure out the type of vocabulary you'll use." Also: "Create a list of common terms, and reference that list to keep your language consistent." |
| F96 | "Match your tone ... a straightforward and direct tone works well for a serious alert about a safety issue ..." (L265) | NOT FOUND | `writing` has "Match your tone to the context." The "safety issue" sentence is not on the page. |
| F97 | Capitalization quote: "title case is generally considered more formal, whereas sentence case is more casual ..." (L267) | CHANGED | `writing`: "Title case is generally considered formal, while sentence case is more casual. Choose a style for each UI element type and use it consistently throughout your app - for example, title case for all alerts or sentence case for all headlines." The meaning is the same. |
| F98 | Menus: title-style capitalization for "menu titles and menu-item labels"; ellipsis rule; articles quote (L269-271) | CHANGED | `menus` Labels: "use title-style capitalization" for menu-item labels. The page text has no rule on menu titles. The ellipsis and articles quotes are exact. |
| F99 | Buttons: "Using title-style capitalization, consider starting the label with a verb ..." (L273) | VERIFIED | `buttons`, Content, exact. |
| F100 | On macOS, SF Pro is "the mandatory platform typeface" (L175) | CHANGED | `typography`, macOS: "SF Pro is the system font in macOS." The word "mandatory" is not there. The page says to follow "the recommended default and minimum text sizes for each platform". |
| F101 | Vibrancy and translucent sidebars are "required by the Apple HIG" (L177) | NOT FOUND | `materials`, macOS: "macOS provides several standard materials with designated purposes". It says "Choose when to allow vibrancy". The `sidebars` page does not require a material. |

## Draft rubric sources

One row per check of draft section 4 (L290-348). The Verdict column rates the "Source" line of the check. The draft header gives each check a tier in brackets. The Hallmark tier of each cited gate follows from the tables above.

| ID | Check and its source line | Verdict | What is wrong or right |
| --- | --- | --- | --- |
| F102 | 1. Silent visible effects (Floor). Gate 16, HIG Feedback and Alerts | CHANGED | Gate 16 is Reflex, class J, not Floor (F34). The HIG support is real: F78, F74, and the Feedback line "people typically expect their action or task to succeed, they only need to know when it doesn't." |
| F103 | 2. Anti-slop copy and no echoes (Floor). Gates 19, 61, 69, HIG Writing and Notifications | CHANGED | Gate 61 is retired (F29). Gate 69 is Reflex (F32). Gate 19 is Floor. "Oops" and exclamation marks come from `craft.md` § 6: "Errors: what happened, why if known, what to do; no *Oops*, no exclamation marks." The best HIG source is Writing: "Interjections like "oops!" or "uh-oh" are typically unnecessary and can sound insincere." The Notifications page covers system notifications, not in-window banners. |
| F104 | 3. Native punctuation (Floor). Gate 63, F1, F2, HIG Menus | CHANGED | Gate 63 is Floor. F1 and F2 are Finish, and they are in `gates.md` § 5, not `SKILL.md`. The HIG menus ellipsis rule is exact (F98). The HIG has no rule on curly quotes. |
| F105 | 4. Capitalization and action verbs (Reflex). HIG Writing, Menus, Buttons, Alerts | CHANGED | No Hallmark gate backs it, so "Reflex" has no source. The rule on articles is for menu items only (F98). "OK" is allowed in informational alerts (F83). An alert title that is a full sentence takes sentence-style capitalization and ending punctuation (F115). The pass example "Delete Track 'Host Mic'?" uses title case on a question. Per the HIG it reads "Delete track 'Host Mic'?". |
| F106 | 5. No eyebrows, tracked caps, mono costume (Floor). Gates 54, 64, 67, F6 | CHANGED | Gates 54 and 67 are Floor. Gate 64 is Reflex. F6 is Finish and covers display-size figures. The tracking threshold is 0.03em, and uppercase at 15px or less also fails (F42). `.monospacedDigit()` is a Swift mapping that no source gives. |
| F107 | 6. SF Symbols only (Floor). Gate 30a, F5, HIG Sidebars and Toolbars | VERIFIED | Gate 30a is Floor, F5 is Finish. HIG: "Consider using familiar symbols to represent items in the sidebar." and "Prefer simple, recognizable symbols for items instead of text". The emoji ban comes from Hallmark only (F67). |
| F108 | 7. Color tokens and button prominence (Floor). Gates 2a, 41, 48, 74, F4, HIG Alerts and Buttons | CHANGED | Tiers: 2a, 41, 48 Floor; 74 Reflex; F4 Finish. The fail example "two equally prominent filled buttons" conflicts with HIG Buttons: "Keep the number of prominent buttons to one or two per view." |
| F109 | 8. Window structure and no nested cards (Reflex). Gate 39, F7, HIG Toolbars, Sidebars, Split Views, Panels | CHANGED | Nested cards are gate 4, Floor (F45). The check says "three or more nested"; gate 4 says one card inside a card. F7 is Finish. The four HIG pages are correct (F85 to F89). |
| F110 | 9. Empty states and long-task progress (Reflex). Gates 68, 70, 81, HIG Progress Indicators and Loading | CHANGED | Gate 68 is Reflex, M. Gate 70 is Floor. Gate 81 is Reflex, R. App scope skips 68 and 81 (F66). The app-screen rule is better: "Every region that loads data has four states: loading ..., empty ..., error ... and full" (`flow.md`). The HIG sources are exact (F90, F91). |
| F111 | 10. Focus, reduced motion, spacing (Floor). Gates 10a, 15, 26a, 27, 33, 71, 72, 73, 75, HIG Feedback and Accessibility | CHANGED | Floor: 10a, 15, 26a, 27, 33, 73. Reflex: 71, 72, 75. The cited HIG page is Feedback, which has no focus or motion text (F92). The fail example "functional labels at 9pt" and the pass rule "at least 11pt (`caption2` or larger)" are wrong for macOS: see F112. |

## Added facts

### HIG text that the draft missed

| ID | Topic | Verdict | Quote and page |
| --- | --- | --- | --- |
| F112 | macOS type sizes | CHANGED | `typography`, "Ensuring legibility" table: macOS default size 13 pt, minimum size 10 pt (iOS: 17 pt and 11 pt). The macOS text styles table: Body 13 pt, Callout 12 pt, Subheadline 11 pt, Footnote 10 pt, Caption 1 and Caption 2 10 pt. Hallmark gate 75 uses 11px for functional text. On macOS, `caption2` is 10 pt. The draft's "11pt (`caption2` or larger)" is wrong. |
| F113 | Alert title and message text | VERIFIED | `alerts`: "Write a title that clearly and succinctly describes the situation ... As much as possible, describe what happened, the context in which it happened, and why." "Include informative text only if it adds value. If you need to add an informative message, keep it as short as possible, using complete sentences, sentence-style capitalization, and appropriate punctuation." |
| F114 | Alert tone | VERIFIED | `alerts`: "In all alert copy, be direct, and use a neutral, approachable tone ... avoid being oblique or accusatory, or masking the severity of the issue." "Avoid explaining alert buttons." |
| F115 | Alert title case rule | VERIFIED | `alerts`: "If the title is a complete sentence, use sentence-style capitalization and appropriate ending punctuation. If the title is a sentence fragment, use title-style capitalization, and don't add ending punctuation." |
| F116 | Alert button text | VERIFIED | `alerts`: "Aim for a one- or two-word title that describes the result of selecting the button." "As with all button titles, use title-style capitalization and no ending punctuation." "Avoid using OK as the default button title unless the alert is purely informational." |
| F117 | Alert button order and default on macOS | VERIFIED | `alerts` (general text, no macOS exception): "Always place the default button on the trailing side of a row or at the top of a stack. Cancel buttons are typically on the leading side of a row or at the bottom of a stack." "Note that you don't want to make a Cancel button the default button." Keyboard: "Pressing Escape (Esc) or Command-Period (.)" cancels an alert on iOS, iPadOS, macOS, and visionOS. |
| F118 | Default button and Return | VERIFIED | `buttons`, Role: "Assign the primary role to the button people are most likely to choose. When a primary button responds to the Return key ..." "Don't assign the primary role to a button that performs a destructive action, even if that action is the most likely choice." |
| F119 | Destructive style on a deliberate action | VERIFIED | `alerts`: "when people deliberately choose a destructive action - such as Empty Trash - the resulting alert doesn't apply the destructive style to the Empty Trash button". Avoid an alert for "common, undoable actions, even when they're destructive". |
| F120 | macOS alert extras | VERIFIED | `alerts`, macOS: "Configure repeating alerts to let people suppress subsequent occurrences". "Use a caution symbol sparingly." Alerts hold "up to three buttons". |
| F121 | Sentence case versus title case | VERIFIED | Alert title: F115. Alert message: sentence-style. Alert and push-button labels: title-style (F116, F99). Menu items: title-style (F98). Notification title: "Use title-style capitalization and no ending punctuation." Notification body: "Use complete sentences, sentence case, and proper punctuation" (`notifications`). Panel title: "a noun phrase with title-style capitalization" (`panels`). |
| F122 | Ellipsis rule | VERIFIED | `menus`: "Append an ellipsis to a menu item's label when the action requires more information before it can complete. The ellipsis character (U+2026) signals that people need to input information or make additional choices". `buttons`, macOS push buttons: "Append a trailing ellipsis to the title when a push button opens another window, view, or app." A progress label may use it: the label "Checkout" can change to "Checking out..." (the HIG writes the ellipsis character). |
| F123 | In-window banners | NOT FOUND | No HIG page names an in-window banner component for macOS. The `notifications` page uses "banner" for a system notification style. Related text follows in F124 to F127. |
| F124 | Prefer in-context status over an alert | VERIFIED | `alerts`: "If you need to provide only information, prefer finding an alternative way to communicate it within the relevant context. For example, when a server connection is unavailable, Mail displays an indicator that people can choose to learn more." Also: "Avoid showing an alert when your app starts ... you could show cached or placeholder data and a nonintrusive label that describes the problem." |
| F125 | Foreground app and notifications | VERIFIED | `notifications`: "Handle notifications gracefully when your app is in the foreground ... present the information in a way that's discoverable but not distracting or invasive, such as incrementing a badge or subtly inserting new data into the current view." |
| F126 | Confirm success sparingly | VERIFIED | `feedback`: "When it makes sense, confirm that a significant action or task has completed ... It's generally best to reserve this type of confirmation for activities that are sufficiently important." Also: "Show people when a command can't be carried out and help them understand why." |
| F127 | Errors near the problem | VERIFIED | `writing`: "When an error message is necessary, display it as close to the problem as possible, avoid blame, and be clear about what someone can do to fix it." "Avoid using we altogether because it may be unclear who the "we" in question refers to ... "Unable to load content" is much clearer." "Avoid robotic error messages with no helpful information, like "Invalid name."" |
| F128 | Empty states | VERIFIED | `writing`: "Provide clear next steps on any blank screens ... give them a button or link to do so if possible. Remember that empty states are usually temporary, so don't show crucial information that could then disappear." |
| F129 | macOS spinners | VERIFIED | `progress-indicators`, macOS: "Avoid labeling a spinning progress indicator." "Prefer an activity indicator (spinner) to communicate the status of a background operation or when space is constrained." |
| F130 | Toolbar items and menu bar | VERIFIED | `toolbars`, macOS: "Make every toolbar item available as a command in the menu bar." Square, help, and image buttons: "avoid placing" them "in a toolbar or status bar" (`buttons`). |

### Apple Style Guide

Source: `https://support.apple.com/guide/applestyleguide/<letter page>/web`. Pages read: C, E, P, S, T, W. The A and D pages answered HTTP 429, so the "alert" entry was not read.

| ID | Topic | Verdict | Quote and page |
| --- | --- | --- | --- |
| F131 | Contractions in UI text | VERIFIED | C page, "contractions": "As part of Apple's informal voice, contractions are used and recommended throughout most documentation, interface text, and marketing copy. Keep localization in mind when deciding how or whether to use contractions." "Don't form contractions from nouns or proper nouns." |
| F132 | Error message (the term) | VERIFIED | E page, "error message": "Don't use except in developer materials. Instead, use message, alert, alert message, or alert sound." The Style Guide has no entry on how to write the text. The HIG Writing page does (F127). |
| F133 | Capitalization of UI | VERIFIED | C page, "capitalization": "Two styles of capitalization are commonly used at Apple" (sentence-style and title-style). "Except for user interface text, guidelines for when to use sentence-style capitalization and when to use title-style capitalization are a matter of department style." "In general, capitalize the names of onscreen elements exactly as they appear onscreen." |
| F134 | Sentence-style and title-style | VERIFIED | S page: "Capitalize only the first letter of the first word, proper nouns, and proper adjectives." T page: "Capitalize each word - except for articles, prepositions of four or fewer letters, and so on." C page: do not capitalize "Prepositions of four letters or fewer", articles, coordinating conjunctions, or "to" in infinitives. |
| F135 | Ellipsis character | VERIFIED | E page, "ellipsis": "Use the ellipsis character (Option-Semicolon) to prevent line breaks from occurring between the dots." "If the name of a menu item or button ends with an ellipsis, don't include the ellipsis in running text." C page, "command names": "Don't include the ellipsis when you refer to the command name in text or text headings." |
| F136 | Colon | VERIFIED | C page, "colons": "In headings: If you use a colon in a heading, capitalize the first word after the colon, regardless of its part of speech." "With lists: Precede every list with a colon". |
| F137 | "please" | VERIFIED | P page: "Avoid using please in instructional text and cross-references." Correct: "Follow the steps below." |
| F138 | "sorry" | NOT FOUND | The S page (`https://support.apple.com/guide/applestyleguide/s-apsge70df12b/web`) has no entry "sorry". No text in the six pages read has "sorry" or "apologize". |
| F139 | Exclamation point | VERIFIED | E page, "exclamation points": "OK to use exclamation points occasionally in promotional text and dialogue. Avoid in documentation." The entry gives no rule for interface text. |
| F140 | "we" and the app name as subject | VERIFIED | W page, "we": "Don't use first person; rewrite in terms of the reader or the product." Correct: "For best results, the image should be at least 600 x 600 pixels." Incorrect: "We recommend that the image be at least 600 x 600 pixels." C page: "Capitalize when referring to the app name". The Style Guide has no entry that makes the app name the subject of a sentence. The HIG Writing page says to avoid "we" in errors (F127). |
| F141 | Alert entry | INCONCLUSIVE | `https://support.apple.com/guide/applestyleguide/a-apsg3acde405/web` returned HTTP 429 on two tries. The entry was not read. |

### Hallmark text that the draft missed

| ID | Topic | Verdict | Quote and file |
| --- | --- | --- | --- |
| F142 | Hallmark has no numeric score | VERIFIED | The only numbers are the 1 to 5 critique (F23), a `sloplint` tally, and the handoff line "`Before   Floor 14 FAIL · Reflex 9`" (`redesign.md` After). `sloplint.mjs` builds the tally from FAIL, REFLEX, WARN, WAIVED, REJECTED, ANSWERED, DISMISSED, NOTE. It exits 1 when there is any FAIL or REFLEX. `gates.md` § 6: "Nothing ships with an open `FAIL` or an open `REFLEX`. A Floor finding is fixed; a Reflex finding is fixed or waived; a Finish finding is read and answered." |
| F143 | How a verdict reads | VERIFIED | `gates.md` § 1: "`FAIL` and `REFLEX` report separately, so "0 FAIL" stays a true statement about the Floor." `SKILL.md`: "A fabricated pass is itself slop." |
| F144 | Finish review first word | VERIFIED | `review-finish.md`: the first line is one of `recapture`, `rebuild`, `fix`, `ship`. It lists "at most eight" findings "ranked by cost to the page". |
| F145 | App-scope review question | VERIFIED | `review-finish.md`: "On an app screen ... Read the full screens at 1440 and 375 and ask what someone fluent in the category would: is the hierarchy clear, is the density even, does every control and table work on a phone, are the states there." |
| F146 | App-scope control height and density | VERIFIED | `flow.md`: "Density is the design. Controls 32 to 40px with a 44px hit target, one container recipe, tables before cards". `craft.md` § 9: "Marketing controls 44 to 52px, app UI 32 to 40px with a 44px hit target (48px on coarse pointers) (39b)". `sloplint-render.mjs` flags "control height outside 32 to 52px" in app scope. Note: these are CSS pixels. HIG Buttons gives "a hit region of at least 44x44 pt". The page has no macOS-specific size. |
| F147 | App-scope four states | VERIFIED | `flow.md`: "Every region that loads data has four states: loading (a skeleton in the shape of what is coming), empty (what belongs here and the one action that fills it), error (what broke and what to do) and full". |
| F148 | App-scope color and shell | VERIFIED | `flow.md`: "The accent marks the primary action, the current selection and state, nothing else". "a sidebar is earned by more than about seven destinations". "a modal is the last answer, after inline editing and disclosure." "a destructive action is undone or confirmed." |
| F149 | App-scope rules that still bind | VERIFIED | `flow.md`: "Everything else binds, the Floor first: tokens, contrast, focus, states, no eyebrow, no tracked-caps label on a table head, no invented figure." |
| F150 | Hallmark copy rules for UI text | VERIFIED | `craft.md` § 6: "Buttons: the verb of the action ... Errors: what happened, why if known, what to do; no *Oops*, no exclamation marks. Empty states: what is empty, why it matters, one action. Loading: a spinner after 150 to 300ms, shown at least 300ms, beside the label; *Loading...* past 2s." "no `--` and no em or en dash (a comma, a colon, a full stop or parentheses instead)". |
| F151 | Hallmark toast rule | VERIFIED | `microinteractions.md`: "Toast. Failures and invisible effects only (16)." `interaction-and-states.md`: success is "The result itself ... no toast (16)". `microinteractions.md`: "Copy to clipboard ... no toast, the label is the feedback." |
| F152 | Model tics list | VERIFIED | `flow.md` Harnesses: "emoji bullets", "drawn SVG or CSS illustrations as filler (80)", "ghost cards (outline-only filler ...)", "a first viewport that commits and a third section that quietly becomes a card grid on white". |
| F153 | The audit sweep for a page Hallmark did not build | VERIFIED | `flow.md`: "Structural findings print, they do not get rebuilt ... A short list with file:line and a one-line fix each". The sweep closes with counts: "`Swept 4 files · fixed 6 · 2 structural findings printed · Floor 0 FAIL`". |

## Sources

Read on 2026-11-24.

Hallmark. Commit `04977e15f3dfd6ee4b74c887dac3eb52665d6c92` on `main` (commit date 2026-11-11). Found with `gh api repos/Nutlope/hallmark/commits/main --jq .sha`.

- `https://github.com/Nutlope/hallmark` and `https://www.usehallmark.com/` (install line)
- `https://raw.githubusercontent.com/Nutlope/hallmark/04977e15f3dfd6ee4b74c887dac3eb52665d6c92/README.md`
- `.../skills/hallmark/SKILL.md`
- `.../skills/hallmark/references/gates.md`, `flow.md`, `redesign.md`, `imagery.md`, `review-finish.md`, `craft.md`, `interaction-and-states.md`, `microinteractions.md`
- `.../skills/hallmark/scripts/sloplint.mjs` and `sloplint-render.mjs`
- `references/structure.md` does not exist at this commit (HTTP 404). The repo tree lists no such file.

Apple HIG (JSON form, `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`): `alerts`, `feedback`, `notifications`, `managing-notifications`, `progress-indicators`, `loading`, `launching`, `toolbars`, `sidebars`, `split-views`, `panels`, `writing`, `menus`, `buttons`, `typography`, `materials`, `sf-symbols`, `accessibility`, `searching`. The public page for each is `https://developer.apple.com/design/human-interface-guidelines/<page>`.

Apple Style Guide: `https://support.apple.com/guide/applestyleguide/welcome/web`, and the letter pages `c-apsgb744e4a3`, `e-apsg076a7313`, `p-apsg4473eab0`, `s-apsge70df12b`, `t-apsg841c3645`, `w-apsg48ccd3b3` under `https://support.apple.com/guide/applestyleguide/<page>/web`. The pages `a-apsg3acde405` and `d-apsg7af4f5d0` returned HTTP 429.
