# BeoSound 9000 glass — character ROM map

**COMPLETE map** — the display's entire character ROM, swept live byte-by-byte 2026-08-04
(the CD-name picker confirmed the glyph set). A CUSTOM B&O ROM — not ASCII, not Latin-1,
not any code page. Send byte `NN` to show the glyph in cell `NN`.

- **Empty cell = blank ROM slot** (byte renders nothing). Only cells holding a glyph render.
- `SP` = the space char (`0x20`). `0x3F` = a real `?`. Real `.` is at `0x2E`.
- **Mostly uppercase-fold:** `0x61–0x7A` (a–z) show as `A–Z` and `0x7B–0x7F` mirror `0x5B–0x5F`
  (so NO lowercase, NO `{ } |` → they show `[ \ ]`). `0x5E`/`0x7E` = **`↑`** (not `^`/`~`).
- **Exception:** `0x60` is NOT folded — it shows a **grave accent `` ` ``** (raised reversed comma), not `@`.
- **Accented glyphs (what beomarquee's `_GLYPH` sends):** `Å=E1 Æ=E2 Ø=E7 Œ=E3 · Ä=D1 Ë=D3 Ï=D5 Ö=D7 Ü=D9 · ß=8D Ñ=8A`

|        | +0      | +1  | +2  | +3  | +4  | +5  | +6  | +7  | +8  | +9  | +A  | +B  | +C  | +D  | +E  | +F  |
|--------|---------|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| **00** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **10** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **20** | `SP`    | `!` | `"` | `#` | `$` | `%` | `&` | `'` | `(` | `)` | `*` | `+` | `,` | `-` | `.` | `/` |
| **30** | `0`     | `1` | `2` | `3` | `4` | `5` | `6` | `7` | `8` | `9` | `:` | `;` | `<` | `=` | `>` | `?` |
| **40** | `@`     | `A` | `B` | `C` | `D` | `E` | `F` | `G` | `H` | `I` | `J` | `K` | `L` | `M` | `N` | `O` |
| **50** | `P`     | `Q` | `R` | `S` | `T` | `U` | `V` | `W` | `X` | `Y` | `Z` | `[` | `\` | `]` | `↑` | `_` |
| **60** | `` ` `` | `A` | `B` | `C` | `D` | `E` | `F` | `G` | `H` | `I` | `J` | `K` | `L` | `M` | `N` | `O` |
| **70** | `P`     | `Q` | `R` | `S` | `T` | `U` | `V` | `W` | `X` | `Y` | `Z` | `[` | `\` | `]` | `↑` | `_` |
| **80** |         |     |     |     |     |     |     |     |     |     | `Ñ` |     |     | `ß` |     |     |
| **90** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **A0** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **B0** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **C0** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| **D0** |         | `Ä` |     | `Ë` |     | `Ï` |     | `Ö` |     | `Ü` |     |     |     |     |     |     |
| **E0** |         | `Å` | `Æ` | `Œ` |     |     |     | `Ø` |     |     |     |     |     |     |     |     |
| **F0** |         |     |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
