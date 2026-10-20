# Save as PDF fixtures

Read by `SaveAsPDFRenderTests` and `SaveAsPDFTests`. Each Office file here is one Quick Look
(`qlmanage -p -o`) writes HTML for on macOS 27.0.1 — the premise `quickLookStillWritesHTML` pins.

| File | Made with | Holds |
|---|---|---|
| `Memo.docx`, `Memo.doc`, `Memo.rtf` | `textutil -convert docx\|doc\|rtf` from a small HTML page | a heading, a bold red run, a list, `SAVEASPDF-WORD-MARKER` |
| `Long.docx` | `textutil -convert docx` | "Long Memo", `Paragraph 001`…`120`, `SAVEASPDF-LONG-END` |
| `Budget.xlsx` | a hand-written SpreadsheetML zip (inline strings, no library) | sheet Spring: `SPRING-ROW-001`…`120`; sheet Autumn: `SAVEASPDF-AUTUMN-MARKER` |
| `Wide.xlsx` | the same | one row of 26 columns ending `SAVEASPDF-WIDE-LASTCOL` |
| `Deck.pptx` | python-pptx 1.0.2, the default template | three title-and-content slides, `SAVEASPDF-SLIDE-1`…`3` |
| `Pictures.pptx` | python-pptx 1.0.2 + Pillow | two blank-layout slides, each one full-slide PNG and no text |
| `PictureWords.pptx` | python-pptx 1.0.2 + Pillow 11.3, Arial drawn into 1920×1440 PNGs | two blank-layout slides, each one full-slide picture of words and no text: “Harvest moon festival” / “Tickets at the north gate”, “Lighthouse keeper rota” / “Lamps lit before dusk” — each title at x 160, y 260 px, the second line at y 960 |

Not every python-pptx deck gets a Quick Look preview — some generated decks in the wild get none —
but these do. If a macOS stops previewing one, `quickLookStillWritesHTML` names it.
