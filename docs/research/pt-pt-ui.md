# European Portuguese terms of the Dirigible UI (R13)

Date: 2026-10-29

This note gives the pt-PT terms that differ from the Brazilian Portuguese (`pt`) terms of the Dirigible UI tables, and the address form of pt-PT. A run that adds or changes a UI string finds its pt-PT term here (decision 0010). Where a term is not here, read the Apple `pt_PT` tables of GarageBand and AppKit [1].

## Facts

### Address

- Apple `pt_PT` texts do not use "você" or "tu". Of 2049 `pt_PT` values whose English text has "you" or "your", 0 have "você" (the `pt` values: 348) [1].
- A question uses "Pretende ...?" (435 values) or "Tem a certeza de que pretende ...?" (280 values). A permission uses "pode". The possessive is "o seu" or "a sua" [1].
- An instruction uses the third person: "clique em", "Experimente reduzir" [1].
- The Microsoft Portuguese (Portugal) style guide, section 4.1.12, gives the same rule: avoid the pronoun "you", and avoid "você" with a new sentence [2].

### Form

- A progress text is "A <infinitive>" ("A gravar", "A exportar"), not a gerund ("Gravando", "Exportando"). The word "gravando" has 0 hits in the `pt_PT` values and 12 in the `pt` values [1].
- Titles are in sentence case: of 2985 English Title Case titles, 2498 end with a lower-case word in `pt_PT` ("Selecionar tudo", "Mostrar inspetor"), and 29 of 2987 in `pt` [1].
- The spelling is the 1990 agreement ("efetuar", "atual", "Selecionar"). The Microsoft guide agrees [2].
- `LocalizationTests.theEuropeanTableHasNoBrazilianWord` fails a pt-PT value with a word of the Brazil-only list. `LocalizationTests` also fails a value that loses the ellipsis of its English value.

### Terms that differ from the pt table

A count is the number of whole-word hits in 13728 Apple values that have both a `pt` and a `pt_PT` text [1].

| English | pt (Brazil) | pt-PT | Note |
|---|---|---|---|
| Track | Pista | Faixa | GarageBand, Music. "pista" 0 hits, "faixa" 249. |
| Take | Tomada | Excerto | GarageBand: "Take %d" is "Excerto %d", "Takes" is "Excertos". |
| Mute | Silenciar | Tirar o som, Sem som | GarageBand, Music. "Tirar o som" for a command, "Sem som" for a state. |
| Loudness | Loudness | Intensidade | CoreAudioKit, Music. Keep "LUFS". |
| Show Inspector | Mostrar Inspetor | Mostrar inspetor | AppKit, Finder. Sentence case. |
| Settings | Ajustes | Definições | AppKit, GarageBand, Music, Voice Memos. |
| System Settings | Ajustes do Sistema | Definições do Sistema | AppKit, Music, System Settings. |
| File | Arquivo | Ficheiro | "arquivo" 0 hits, "ficheiro" 263. |
| Save | Salvar | Guardar | AppKit, GarageBand. "salvar" 0 hits. |
| Save As | Salvar Como | Guardar como | AppKit, GarageBand. |
| Select All | Selecionar Tudo | Selecionar tudo | AppKit. Sentence case. |
| Rename | Renomear | Alterar nome | AppKit, Finder, GarageBand, Voice Memos. |
| Edit (menu) | Editar | Edição | AppKit menu title. |
| View (menu) | Visualizar | Visualização | AppKit, GarageBand, Music. |
| Quit | Encerrar | Sair | AppKit, GarageBand, Music. "Quit %@" is "Sair de %@". |
| Try Again | Tentar Novamente | Voltar a tentar | GarageBand, Music, Finder, QuickTime Player. |
| Pause | Pausar | Pausa | GarageBand, Music. |
| Screen | Tela | Ecrã | "tela" 0 hits, "ecrã" 83. |
| User | Usuário | Utilizador | "usuário" 0 hits, "utilizador" 23. |
| Download | Download | Descarga | "download" 0 hits, "descarga" 75. |
| Are you sure you want to ...? | Tem certeza de que deseja ...? | Tem a certeza de que pretende ...? | Music, GarageBand. "tem certeza" 0 hits, "tem a certeza" 222. |
| Do you want to ...? | Deseja ...? | Pretende ...? | GarageBand, Music. |

## Sources

1. Apple `pt_PT.lproj` and `pt.lproj` string tables of macOS 15 apps that have an English, a `pt`, and a `pt_PT` text: GarageBand, AppKit, Voice Memos, Music, QuickTime Player, Keynote, Finder, System Settings, CoreAudioKit, and AVKit (183 tables, 33020 `pt_PT` values), read 2026-10-29 in run 2026-10-29-pt-pt-ui.
2. Microsoft Portuguese (Portugal) Localization Style Guide, section 4.1.12 Pronouns: https://download.microsoft.com/download/9/9/5/995a8ca6-383c-439d-9db0-cd457c9c2724/por-prt-StyleGuide.pdf
