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
| `Mixed.pptx` | python-pptx 1.0.2 + Pillow 11.3, Arial 120 and 96 px into a 1920×1440 PNG | slide 1 title-and-content, “Mixed Deck” / `SAVEASPDF-MIXED-TEXT`; slide 2 blank layout, one full-slide picture of “Orchard harvest supper” (x 160, y 260 px) / “Cider pressed at noon” (y 960) and no text |
| `FourPictures.docx` | python-docx 1.2.0 + Pillow 11.3 | 40 lines, then four 1920×1440 PNGs 6 in wide, `SAVEASPDF-FOUR-PICTURES-END` |
| `FourPictures.xlsx` | xlsxwriter 3.2.9 + the same PNGs | `ROW-001`…`260` in column A, the pictures at 30 % in column B from rows 61, 121, 181 and 241, `SAVEASPDF-FOUR-PICTURES-END` |

The four pictures are one hue each — red, green, blue, yellow — a light field with darker stripes of
the same hue, so a test can tell them apart by colour.

Not every python-pptx deck gets a Quick Look preview — some generated decks in the wild get none —
but these do. If a macOS stops previewing one, `quickLookStillWritesHTML` names it.
