# 1945k III / Solite Spirits / Flag Rally system spec (SPR800E board)

Source of record: MAME `promat/1945kiii.cpp`, vendored at
`reference/mame/1945kiii.cpp` (master ed715993, 2026-10-02). Every fact
below cites a line of that file as `L<n>`. Facts measured in MAME 0.288
with the oracle (`sim/mame/k3_oracle.lua`) are marked **[oracle]** and
detailed in `docs/m0_findings.md`. Anything MAME marks as a guess is listed
in section 13 and is not to be treated as hardware truth.

## 1. Sets

| Set | Parent | Machine config | Inputs | Rotation | Year, maker | Line |
|---|---|---|---|---|---|---|
| 1945kiii | - | k3 | k3 | ROT270 | 2000 Oriental Soft, OPCX2 PCB | L862 |
| 1945kiiin | 1945kiii | k3 | k3 | ROT270 | 2000 Oriental Soft, OPCX1 PCB | L863 |
| 1945kiiio | 1945kiii | k3 | k3old | ROT270 | 1999 Oriental Soft, OPCX1 PCB | L864 |
| 1945kiiipt | 1945kiii | k3 | solite | ROT270 | 1999 Promat licence, OPCX1 PCB | L865 |
| slspirit | - | k3 | solite | ROT270 | 1999 Promat | L866 |
| flagrall | - | flagrall | flagrall | ROT0 | 1996 "Promat?" | L868 |

1945K III is a retooled Solite Spirits (L17-20). Flag Rally is a racing
game, not a shooter, but it runs on the same board family and comes along
with the core.

## 2. Board

Two PCBs are documented (L37-100):

- OPCX2 (1945kiii): 68000, SPR800E (QFP208, "OP-CX1"), QuickLogic QL2003
  (PLCC84), two AD-65 (OKI M6295 clones), crystals 16 MHz and 27 MHz,
  two KM681000 (128K x 8 SRAM), two 62256 (32K x 8), six 6116 (2K x 8),
  DSW1/DSW2 (L37-60).
- OPCX1 (1945kiiin, 1945kiiio, 1945kiiipt, slspirit by its ROM names):
  same chips plus a 4.000 MHz crystal, a reset button and a volume pot
  (L69-95).
- PCB notes for OPCX2: 68000 16.000 MHz, both M6295 at 1.000 MHz, sample
  rate 1000000/132, VSync 60 Hz (L62-65).

RAM inventory against the memory map (inference, not from the driver):
the two 62256 match the 64 KB main RAM at 0x100000; the 6116s cover
palette (1 KB), sprite RAM (2 x 4 KB) and tile RAM (4 KB). The two
KM681000 (2 x 128 KB) next to the SPR800E have no counterpart in the MAME
memory map. 2 x 128 KB is enough for two 320 x 240 x 8-bit frames, so a
double-buffered sprite (or whole-screen) framebuffer is plausible, and it
would fit MAME's per-frame sprite cycle budget (section 8.4). This is
research item R1, not an assumption: MAME renders straight to the screen.

## 3. CPU and interrupts

- Main CPU: MC68000 at MASTER_CLOCK = XTAL 16 MHz (L655, L660), MAME
  comment `// ?` on the clock (L660); the OPCX2 notes measure 16.000 MHz
  (L63).
- One interrupt: IRQ4 at vblank, `irq4_line_hold` (L662): asserted when the
  vblank starts (first line after the visible area) and released when the
  CPU acknowledges it.
- No sound CPU. The 68000 drives the M6295s directly.

## 4. Memory map

Common (`k3_base_map`, L371-389). Word addresses, 16-bit bus.

| Range | Use | Line |
|---|---|---|
| 0x000000-0x0fffff | program ROM (1 MB region) | L377 |
| 0x0009ce-0x0009d3 | writes ignored (no-op, "bug in code?") | L373-375 |
| 0x100000-0x10ffff | main RAM, 64 KB | L378 |
| 0x200000-0x2003ff | palette RAM, 0x200 words | L379 |
| 0x240000-0x240fff | sprite RAM 1 (`spritera1`), 0x800 words | L380 |
| 0x280000-0x280fff | sprite RAM 2 (`spritera2`), 0x800 words | L381 |
| 0x2c0000-0x2c07ff | tile RAM (`bgram`), 0x400 words = 32 x 32 map | L382 |
| 0x2c0800-0x2c0fff | RAM, "or does k3 have a bigger tilemap?" | L383 |
| 0x340000-0x340001 | scroll X (write) | L384 |
| 0x380000-0x380001 | scroll Y (write) | L385 |
| 0x400000-0x400001 | INPUTS (read) | L386 |
| 0x440000-0x440001 | SYSTEM (read) | L387 |
| 0x480000-0x480001 | DSW (read, both banks as one word) | L388 |

k3 additions (`k3_map`, L391-400):

| Range | Use | Line |
|---|---|---|
| 0x3c0000-0x3c0001 | control: buffer flip-flop, OKI banks (section 9) | L395 |
| 0x4c0001 | OKI 1 (`oki1`), low byte, cswidth 16 | L397 |
| 0x500001 | OKI 2 (`oki2`), low byte, cswidth 16 | L398 |
| 0x8c0000-0x8cffff | RAM, "not used? (bug in code?)" | L399 |

flagrall additions (`flagrall_map`, L403-409): control at 0x3c0000 with
its own decode (L407), OKI 1 at 0x4c0001 (L408). No second OKI, no
0x8c0000 RAM.

**[oracle]** 1945kiii writes 0x8c0000-0x8c0ffe (4 KB) with zeros 10 times
during boot (frames 22-36) and reads it back the same number of times
(20,480 writes, 20,480 reads in 12,000 frames): a boot RAM test. The core
must provide RAM there. 0x2c0800-0x2c0fff is never written or read in
any capture. ROM-space writes hit 0x00098a-0x0009d2 (5 addresses), all
ignored by MAME (ROM).

## 5. Video timing

| Config | Pixel clock | Htotal | Hvisible | Vtotal | Vvisible | Frame rate | Line |
|---|---|---|---|---|---|---|---|
| k3 | 27 MHz / 4 = 6.75 MHz | 432 | 0-319 | 262 | 0-223 | 59.64 Hz | L689 |
| flagrall | 27 MHz / 4 = 6.75 MHz | 432 | 0-319 | 315 | 0-239 | 49.61 Hz | L667 |

MAME gives no blanking or sync positions: `set_raw` puts the visible area
at the start of the line and frame (hbstart 320, vbstart 224/240). The
flagrall timing has a video reference (L667 comment). VSync "60Hz" on the
OPCX2 board (L65) agrees with 59.64 Hz.

**[oracle]** the frame notifier (vblank start) is at line 224 hpos 0 (k3).

## 6. Palette

0x200 entries, `xBGR_555` (L671): word bits 0-4 red, 5-9 green, 10-14
blue, bit 15 unused; each 5-bit value expands as `(v << 3) | (v >> 2)`.
Written through `palette_device::write16` (L379). Entries 0x000-0x0FF
serve the tilemap, 0x100-0x1FF the sprites (sections 7, 8).

## 7. Tilemap (background)

- One layer: 32 x 32 tiles of 16 x 16, `TILEMAP_SCAN_ROWS` (L177), so the
  map is 512 x 512 pixels and tile (col, row) is word `row * 32 + col`.
- Tile code = the whole 16-bit buffered word, gfx 1 (`tiles`), colour 0,
  no flip (L169-173). The tilemap fetches `code % tile count` (MAME
  tilemap lookup): 8,192 tiles in k3 sets (2 MB), 4,096 in flagrall (1 MB).
- Graphics: `gfx_16x16x8_raw` (L652): 256 bytes per tile, one byte per
  pixel, rows top to bottom, pixels left to right; the byte is the pen.
  GFXDECODE colour base 0x000, 2 colours of 256 (L651-652), so tile pixel
  pen p uses palette entry 0x000 + p.
- Opaque: no transparent pen is set and `draw(..., 0, 0)` (L300), so
  every pixel, pen 0 included, is drawn.
- Scroll: `set_scrollx(0, data)`, `set_scrolly(0, data)` with the full
  written word (L325-333). Screen pixel (x, y) shows map pixel
  ((x + scrollx) mod 512, (y + scrolly) mod 512) **[oracle: pixel-exact on
  every frame]**.
- The tilemap reads `m_bgram_buffer`, not the CPU-visible RAM (L171),
  section 9.

## 8. Sprites

### 8.1 List format

Entry i (0..2047) is word i of the buffered sprite RAM 1 (`a`) and word i
of buffered sprite RAM 2 (`b`) (L273-275, L292-293):

| Field | Bits | Line |
|---|---|---|
| X | `a[15:8]` low 8 bits, `b[0]` bit 8 (9 bits, 0-511) | L283 |
| Y | `a[7:0]` (8 bits, 0-255) | L284 |
| tile | `b[14:1]` (14 bits) | L285 |
| flicker | `b[15]` | L286 |

No flip, no size, no colour field: every sprite is one 16 x 16 tile,
colour 1 (L288).

### 8.2 Graphics

`gfx_16x16x8_raw` from region `sprites` (L651), same layout as the tiles,
colour base 0x000, colour 1 with granularity 256, so the palette base is
0x100 (L195, L288). Tile index is taken modulo the tile count (L196):
16,384 tiles in the k3 sets (4 MB), 12,288 in flagrall (3 MB), where the
14-bit field can address past the end.

### 8.3 Drawing

- Drawn in list order, entry 0 first, later entries on top (L277-295).
- Pen 0 transparent (L288 passes `transparent_color` 0, L248).
- Flicker set: every non-transparent pixel is written as palette entry
  `0x100 | 0xff` = 0x1FF instead of its own pen ("verified from PCB",
  L250-253).
- Four copies per entry for wrap-around: (X, Y), (X, Y - 256),
  (X - 512, Y), (X - 512, Y - 256) (L288-291), clipped to the visible area.
- Sprites are drawn over the opaque tilemap; no priority bits (L298-302).

### 8.4 Cycle budget

`draw_sprites` adds 4 + 128 "cycles" per entry and stops when the running
total exceeds `screen width * height` (L270-281), with width and height the
TOTAL raster (432 x 262 = 113,184 for k3; 432 x 315 = 136,080 for
flagrall). Entry i is drawn when (i + 1) x 132 <= that total, so only the
first 857 entries (k3) or 1,030 entries (flagrall) are ever drawn. Both the
per-entry cost and the "whole screen" limit are TODOs in MAME (L266-267,
L270, L279), backed only by a video reference (L266). Research item R2.

**[oracle]** No capture comes near the limit: the most entries that draw a
visible pixel in one frame is 381 (1945kiii attract) and 450 (flagrall
gameplay); the highest such index is 425 (k3 sets) and 799 (flagrall).
The most entries covering a single line is 63.

## 9. Buffered VRAM (control register)

`vram_buffer(newval)` (L305-323): on a 0 -> 1 transition of its argument it
copies both sprite RAMs and the tile RAM into the buffers the renderer
reads (`m_spriteram_buffer[0..1]`, `m_bgram_buffer`) and marks the tilemap
dirty. The argument is stored as the new flip-flop state.

- k3 (L335-346), write to 0x3c0000:
  - bit 0: "VRAM access flip-flop", copy on its rising edge (L341, L343)
  - bit 1: OKI 1 bank (L340, L345)
  - bit 2: OKI 2 bank (L339, L344)
  - bit 4: unknown (L338)
- flagrall (L348-368): `data &= mem_mask`; copy on the falling edge of
  bit 5 (`vram_buffer(BIT(~data, 5))`, L363); OKI 1 bank = bits 2:1 (L367);
  bits 0x0001, 0x0008, 0x0040, 0x0080 unknown, 0x0010 "always on?", 0x0100
  and 0x0200 seen at startup (L352-361).

**[oracle] 1945kiii:** every frame the IRQ4 handler writes 0x14 (bit 0
clear) at line 224 and 0x15 (bit 0 set, the copy) at line 257, inside the
vblank; when the game lags, the copy is skipped for 1-3 frames (the same
buffer is shown again). Six copies per 12,000 frames happen in the visible
area (lines 113-115), at scene changes. MAME renders the whole frame at
vblank, so a mid-frame copy shows in the entire frame; on a line renderer
it would split the frame. See R3.

Scroll writes: **[oracle]** at line 257 (vblank) on every frame except one
at boot; scroll is not buffered by the flip-flop in MAME (it goes straight
to the tilemap, L325-333) but in practice it changes only in vblank.

## 10. Sound

- k3: two OKI M6295, `MASTER_CLOCK / 16` = 1 MHz, pin 7 high (L675,
  L686), i.e. 1,000,000 / 132 = 7,575.76 Hz sample rate, mixed mono 1:1
  (L676, L687). MAME notes the OPCX2 runs them from 16 MHz / 16 and the
  OPCX1 from 4 MHz / 4 (L686): the same 1 MHz.
- Each k3 OKI region is 0x80000 (L699-703); the M6295 addresses 256 KB, so
  the bank bit selects the lower or upper 256 KB (`set_rom_bank`, L344-345).
- flagrall: one OKI (L675), region 0x100000 with 0xC0000 loaded (L838-841,
  "3x banks"), bank = bits 2:1 of the control word (L367), so bank 3 reads
  the unloaded (zero) last quarter.
- OKI ports: k3 `0x4c0001` (oki1) and `0x500001` (oki2), byte lane 0
  with cswidth 16 (L397-398); flagrall `0x4c0001` (L408).

**[oracle]** 1945kiii, 12,000 attract frames: 4,040 writes to oki1, 34 to
oki2.

## 11. Inputs and DIP switches

All ports are 16 bits, active low.

INPUTS (0x400000), every set except flagrall (L413-429): bit 0-3 P1 up,
down, left, right; bits 4-7 P1 buttons 1-4; bits 8-11 P2 up, down, left,
right; bits 12-15 P2 buttons 1-4. flagrall (L588-597): bits 0-3 P1
directions, bits 4-5 buttons 1-2, the rest unused.

SYSTEM (0x440000): bit 0 coin 1, bit 1 unknown (k3 sets; flagrall coin 2),
bit 2 start 1, bit 3 start 2 (k3 sets; flagrall unknown) (L431-436,
L599-608).

DSW (0x480000), defaults in brackets:

- k3 (L438-470): SW1:1-3 coin A [1C_1C 0x7]; SW1:4-5 difficulty [normal
  0x08]; SW1:6-7 lives [3, 0x60]; SW1:8 service [off]; SW2:1 demo sounds
  [on, 0]; SW2:2 allow continue [yes, 0x200]; SW2:3-8 unknown [1]. Default
  word 0xFEEF.
- k3old (1945kiiio, L474-528): as k3 but SW1:1-3 values 0, 1, 2 all mean
  1C_1C (L505-507) and SW2:1-2 unknown (demo sounds always off, always
  continue, L521-522). Default 0xFFEF.
- solite (1945kiiipt, slspirit, L532-584): as k3old, SW1:6-7 unknown (L573-574).
  Default 0xFFEF.
- flagrall (L610-647): SW1:1-2 coinage [1C_1C 3]; SW1:5 demo sounds [on,
  0]; SW1:6 "Dip Control" [off]; SW1:8 picture test [off]; SW2:1-2 lives
  [3, 0x300]; SW2:3 bonus type [0, 0x400]; SW2:5-6 difficulty [normal
  0x3000]; SW2:8 free play [off]. Default 0xFFEF.

**[oracle]** these default words are the DSW port values MAME 0.288
reads at power-on for each set (INPUTS and SYSTEM idle at 0xFFFF).

## 12. ROMs

Regions (L694-857):

| Region | k3 sets | flagrall | Load |
|---|---|---|---|
| maincpu | 0x100000 | 0x100000 | ROM_LOAD16_BYTE pairs (odd file at +1) |
| oki1 | 0x80000 | 0x100000 | ROM_LOAD |
| oki2 | 0x80000 | - | ROM_LOAD |
| sprites | 0x400000 | 0x300000 | ROM_LOAD32_WORD (1945kiii) or ROM_LOAD32_BYTE x4 |
| tiles | 0x200000 | 0x100000 | ROM_LOAD (1945kiii, flagrall) or ROM_LOAD32_BYTE x4 |
| plds | 0x117 (1945kiiipt only, NO_DUMP, unused) | - | |

The full per-file table (name, region offset, size, CRC32, SHA1) is
generated from the driver by `tools/check_roms.py --table` and reproduced
in Appendix A. Notes from the driver: 1945kiii program ROMs have identical
halves (L696-697); 1945kiiio program ROMs are 0x00 padded from 0x40000
(L744-745); the 1945kiiin/1945kiiio tile ROMs are M16M-3.U61 split in four
(L737, L765); 1945kiiipt sprites u5-u8 and u58-u60 match Solite Spirits,
u61 does not (L783-791).

## 13. MAME uncertainties (research items in PLAN.md)

| # | Item | Line |
|---|---|---|
| U1 | 68000 clock `// ?` (PCB notes say 16.000 MHz on OPCX2) | L660, L63 |
| U2 | OKI clock "dividers?" (PCB notes say 1.000 MHz) | L675, L686, L64 |
| U3 | Sprite cycle budget: 4 + 128 per entry and "related to whole screen?" | L266-267, L270, L279 |
| U4 | 0x2c0800-0x2c0fff: bigger tilemap? | L383 |
| U5 | 0x8c0000 RAM "not used? (bug in code?)" (but the game RAM-tests 4 KB of it) | L399 |
| U6 | Writes to 0x9ce-0x9d3 "bug in code?" | L373-375 |
| U7 | Control bit 4 (k3) and most flagrall control bits unknown | L338, L352-361 |
| U8 | What the "VRAM access flip-flop" really does: MAME copies on an edge; hardware may swap banks | L341, L305-323 |
| U9 | Blanking and sync positions (not given) | L667, L689 |
| U10 | Flag Rally is credited to "Promat?" | L868 |

## Appendix A. ROM table

Generated by `python3 tools/check_roms.py --table` from the vendored driver.

| Set | Region | File | Load | Offset | Size | CRC32 | SHA1 | Line |
|---|---|---|---|---|---|---|---|---|
| 1945kiii | maincpu | prg-1.u51 | LOAD16_BYTE | 0x000001 | 0x80000 | 6b345f27 | 60867fa0e2ea7ebdd4b8046315ee0c83e5cf0d74 | L696 |
| 1945kiii | maincpu | prg-2.u52 | LOAD16_BYTE | 0x000000 | 0x80000 | ce09b98c | a06bb712b9cf2249cc535de4055b14a21c68e0c5 | L697 |
| 1945kiii | oki2 | snd-2.su4 | LOAD | 0x000000 | 0x80000 | 47e3952e | d56524621a3f11981e4434e02f5fdb7e89fff0b4 | L700 |
| 1945kiii | oki1 | snd-1.su7 | LOAD | 0x000000 | 0x80000 | bbb7f0ff | 458cf3a0c2d42110bc2427db675226c6b8d30999 | L703 |
| 1945kiii | sprites | m16m-1.u62 | LOAD32_WORD | 0x000000 | 0x200000 | 0b9a6474 | 6110ecb17d0fef25935986af9a251fc6e88e3993 | L706 |
| 1945kiii | sprites | m16m-2.u63 | LOAD32_WORD | 0x000002 | 0x200000 | 368a8c2e | 4b1f360c4a3a86d922035774b2c712be810ec548 | L707 |
| 1945kiii | tiles | m16m-3.u61 | LOAD | 0x000000 | 0x200000 | 32fc80dd | bee32493a250e9f21997114bba26b9535b1b636c | L710 |
| 1945kiiin | maincpu | u34 | LOAD16_BYTE | 0x000001 | 0x80000 | d0cf4f03 | 3455927221afae5103c02b12c1b855f416c47e91 | L715 |
| 1945kiiin | maincpu | u35 | LOAD16_BYTE | 0x000000 | 0x80000 | 056c64ed | b0eddad9c950676b94316d3aeb32f3ed4b9ade0f | L716 |
| 1945kiiin | oki2 | snd-2.su4 | LOAD | 0x000000 | 0x80000 | 47e3952e | d56524621a3f11981e4434e02f5fdb7e89fff0b4 | L719 |
| 1945kiiin | oki1 | snd-1.su7 | LOAD | 0x000000 | 0x80000 | bbb7f0ff | 458cf3a0c2d42110bc2427db675226c6b8d30999 | L722 |
| 1945kiiin | sprites | u5 | LOAD32_BYTE | 0x000000 | 0x80000 | f328f85e | fe1e1b86a77a9b6da0f69b20da64e69b874d8ef9 | L725 |
| 1945kiiin | sprites | u6 | LOAD32_BYTE | 0x000001 | 0x80000 | cfdabf1b | 9822def10e5213d1b5c86034637481b5349bfb70 | L726 |
| 1945kiiin | sprites | u7 | LOAD32_BYTE | 0x000002 | 0x80000 | 59a6a944 | 20a109edddd8ab9530b94b3b2d2f8a85af2c08f8 | L727 |
| 1945kiiin | sprites | u8 | LOAD32_BYTE | 0x000003 | 0x80000 | 59995aaf | 29c2c638b0dd2bf1e79707ea6f5b38b37f45b822 | L728 |
| 1945kiiin | sprites | u58 | LOAD32_BYTE | 0x200000 | 0x80000 | 6acf2ce4 | 4b18678a9e03beb24494270d19c57bca32a72592 | L730 |
| 1945kiiin | sprites | u59 | LOAD32_BYTE | 0x200001 | 0x80000 | ca6ff210 | d7e476bb41c193654495f5ed6ba39980cb3660bc | L731 |
| 1945kiiin | sprites | u60 | LOAD32_BYTE | 0x200002 | 0x80000 | 91eb038a | b24082ba1675e87881a321ba87e079a1a027dfa4 | L732 |
| 1945kiiin | sprites | u61 | LOAD32_BYTE | 0x200003 | 0x80000 | 1b358c6d | 1abe6422b420fd064a32ed9ca9a28c85996d4e57 | L733 |
| 1945kiiin | tiles | 5.u102 | LOAD32_BYTE | 0x000000 | 0x80000 | 91b70a6b | e53f62212d6e3ab5f892944b1933385a85e0ba8a | L736 |
| 1945kiiin | tiles | 6.u103 | LOAD32_BYTE | 0x000001 | 0x80000 | 7b5bfb85 | ef59d64513c7f7e6ee3dcc9bb7bb0e14a71ca957 | L737 |
| 1945kiiin | tiles | 7.u104 | LOAD32_BYTE | 0x000002 | 0x80000 | cdafcedf | 82becd002a16185220131085db6576eb763429c8 | L738 |
| 1945kiiin | tiles | 8.u105 | LOAD32_BYTE | 0x000003 | 0x80000 | 2c3895d5 | ab5837d996c1bb70071db02f07412c182d7547f8 | L739 |
| 1945kiiio | maincpu | 3.u34 | LOAD16_BYTE | 0x000001 | 0x80000 | 5515baa0 | 6fd4c9b7cc27035d6baaafa73f5f5930bfde62a4 | L744 |
| 1945kiiio | maincpu | 4.u35 | LOAD16_BYTE | 0x000000 | 0x80000 | fd177664 | 0ea1854be8d88577129546a56d13bcdc4739ae52 | L745 |
| 1945kiiio | oki2 | s21.su5 | LOAD | 0x000000 | 0x80000 | 9d96fd55 | 80025cc2c44e8cd938620818e0b0974026377f5c | L748 |
| 1945kiiio | oki1 | s13.su4 | LOAD | 0x000000 | 0x80000 | d45aec3b | fc182a10e19687eb2f2f4a1d2ad976814185f0fc | L751 |
| 1945kiiio | sprites | 9.u5 | LOAD32_BYTE | 0x000000 | 0x80000 | be0f432e | 7d63f97a8cb38c5351f2cd2f720de16a0c4ab1d7 | L754 |
| 1945kiiio | sprites | 10.u6 | LOAD32_BYTE | 0x000001 | 0x80000 | cf9127b2 | e02f436662f47d8bb5a9d726889c6e86cf64bdcf | L755 |
| 1945kiiio | sprites | 11.u7 | LOAD32_BYTE | 0x000002 | 0x80000 | 644ee8cc | 1742e31ba48a93c005cce0dc575d9b5d739d1dce | L756 |
| 1945kiiio | sprites | 12.u8 | LOAD32_BYTE | 0x000003 | 0x80000 | 0900c208 | 9446382d274dc7b6ccdf18738aa4db636fd9e3c9 | L757 |
| 1945kiiio | sprites | 13.u58 | LOAD32_BYTE | 0x200000 | 0x80000 | 8ea9c6be | baf3af389417e1f14d0c38d8c872839a54008909 | L759 |
| 1945kiiio | sprites | 14.u59 | LOAD32_BYTE | 0x200001 | 0x80000 | 10c18fb4 | 68934e73cfb6a49a4c1639dcb4c49246f16179b2 | L760 |
| 1945kiiio | sprites | 15.u60 | LOAD32_BYTE | 0x200002 | 0x80000 | 86ab6c7c | 59acaee6ba78a22f1423832a116ad41e19522aa1 | L761 |
| 1945kiiio | sprites | 16.u61 | LOAD32_BYTE | 0x200003 | 0x80000 | ff419080 | 542819bdd60976bddfa96570321ba3f7fb6fbf23 | L762 |
| 1945kiiio | tiles | 5.u102 | LOAD32_BYTE | 0x000000 | 0x80000 | 91b70a6b | e53f62212d6e3ab5f892944b1933385a85e0ba8a | L765 |
| 1945kiiio | tiles | 6.u103 | LOAD32_BYTE | 0x000001 | 0x80000 | 7b5bfb85 | ef59d64513c7f7e6ee3dcc9bb7bb0e14a71ca957 | L766 |
| 1945kiiio | tiles | 7.u104 | LOAD32_BYTE | 0x000002 | 0x80000 | cdafcedf | 82becd002a16185220131085db6576eb763429c8 | L767 |
| 1945kiiio | tiles | 8.u105 | LOAD32_BYTE | 0x000003 | 0x80000 | 2c3895d5 | ab5837d996c1bb70071db02f07412c182d7547f8 | L768 |
| 1945kiiipt | maincpu | u34 | LOAD16_BYTE | 0x000001 | 0x80000 | d4efcdf4 | e53ea3a5d8a44d4adf5e58865f99548d3476d1f5 | L773 |
| 1945kiiipt | maincpu | u35 | LOAD16_BYTE | 0x000000 | 0x80000 | 4381341d | 518c1b303d6286a794faf6d5731fbe7c51936b86 | L774 |
| 1945kiiipt | oki2 | su5 | LOAD | 0x000000 | 0x80000 | 9d96fd55 | 80025cc2c44e8cd938620818e0b0974026377f5c | L777 |
| 1945kiiipt | oki1 | su4 | LOAD | 0x000000 | 0x80000 | d45aec3b | fc182a10e19687eb2f2f4a1d2ad976814185f0fc | L780 |
| 1945kiiipt | sprites | u5 | LOAD32_BYTE | 0x000000 | 0x80000 | 4742aa38 | 6e8d53afe7a6a5d60c135dd6a283d5bb47821f48 | L783 |
| 1945kiiipt | sprites | u6 | LOAD32_BYTE | 0x000001 | 0x80000 | c137fb33 | 6798bc4569bdcab02c2b16315c8827268e5674eb | L784 |
| 1945kiiipt | sprites | u7 | LOAD32_BYTE | 0x000002 | 0x80000 | d0593a03 | 544e345e0849239b8156df8c50568bb2e2685bd3 | L785 |
| 1945kiiipt | sprites | u8 | LOAD32_BYTE | 0x000003 | 0x80000 | baa9eeb1 | 12d905143c707bc0ff6997b89816b7bce40bd9aa | L786 |
| 1945kiiipt | sprites | u58 | LOAD32_BYTE | 0x200000 | 0x80000 | eb586bd6 | 1050021a663421be455c215cb9e724463e1fc425 | L788 |
| 1945kiiipt | sprites | u59 | LOAD32_BYTE | 0x200001 | 0x80000 | abc8b869 | aea3e2bb447b6b9ac0dd19cac7922cc9bee6afb8 | L789 |
| 1945kiiipt | sprites | u60 | LOAD32_BYTE | 0x200002 | 0x80000 | 31f9b034 | d3224d9f11236fcaa65d477b87c46bea8a69db01 | L790 |
| 1945kiiipt | sprites | u61 | LOAD32_BYTE | 0x200003 | 0x80000 | f13e609b | 03ab2ee368d086a927d2b6412db5f6dfd066b08f | L791 |
| 1945kiiipt | tiles | u102 | LOAD32_BYTE | 0x000000 | 0x80000 | ddca369b | 66c3daf55cbe5d5f73482eff566c52fe1e509164 | L794 |
| 1945kiiipt | tiles | u103 | LOAD32_BYTE | 0x000001 | 0x80000 | 32f58186 | 9eab278ce69387e04c90b660686e93e3d7c80439 | L795 |
| 1945kiiipt | tiles | u104 | LOAD32_BYTE | 0x000002 | 0x80000 | 2031c42e | f7132862ac0b908da298d67802266b96f809ff49 | L796 |
| 1945kiiipt | tiles | u105 | LOAD32_BYTE | 0x000003 | 0x80000 | 8428b693 | ee9d1a295159c5bbf5c0a59cf3cd23889aa293f7 | L797 |
| 1945kiiipt | plds | gal16v8.u22 | LOAD | 0x000000 | 0x117 | NO_DUMP | - | L800 |
| slspirit | maincpu | 3.u34 | LOAD16_BYTE | 0x000001 | 0x40000 | b5ac3272 | da223ef3b006be03a11559e00ae9d7bbd2d06ee5 | L805 |
| slspirit | maincpu | 4.u35 | LOAD16_BYTE | 0x000000 | 0x40000 | 86397bcb | 562dbb82c363039152aa574df72f73e9f71805d9 | L806 |
| slspirit | oki2 | s21.su5 | LOAD | 0x000000 | 0x80000 | d4cbc27c | feffa530baa4d70788a3598a12761827694a6275 | L809 |
| slspirit | oki1 | s13.su4 | LOAD | 0x000000 | 0x80000 | d9c63d55 | 7fd2fc08c859947dd4b1490132597ae23fcbed36 | L812 |
| slspirit | sprites | 9.u5 | LOAD32_BYTE | 0x000000 | 0x80000 | 4742aa38 | 6e8d53afe7a6a5d60c135dd6a283d5bb47821f48 | L815 |
| slspirit | sprites | 10.u6 | LOAD32_BYTE | 0x000001 | 0x80000 | c137fb33 | 6798bc4569bdcab02c2b16315c8827268e5674eb | L816 |
| slspirit | sprites | 11.u7 | LOAD32_BYTE | 0x000002 | 0x80000 | d0593a03 | 544e345e0849239b8156df8c50568bb2e2685bd3 | L817 |
| slspirit | sprites | 12.u8 | LOAD32_BYTE | 0x000003 | 0x80000 | baa9eeb1 | 12d905143c707bc0ff6997b89816b7bce40bd9aa | L818 |
| slspirit | sprites | 13.u58 | LOAD32_BYTE | 0x200000 | 0x80000 | eb586bd6 | 1050021a663421be455c215cb9e724463e1fc425 | L820 |
| slspirit | sprites | 14.u59 | LOAD32_BYTE | 0x200001 | 0x80000 | abc8b869 | aea3e2bb447b6b9ac0dd19cac7922cc9bee6afb8 | L821 |
| slspirit | sprites | 15.u60 | LOAD32_BYTE | 0x200002 | 0x80000 | 31f9b034 | d3224d9f11236fcaa65d477b87c46bea8a69db01 | L822 |
| slspirit | sprites | 16.u61 | LOAD32_BYTE | 0x200003 | 0x80000 | c1fc95e5 | 2597e8553deb751d1a199c4eb3f321f0564b9c76 | L823 |
| slspirit | tiles | 5.u102 | LOAD32_BYTE | 0x000000 | 0x80000 | 9f0855a6 | 13aa54641eb188f604cf32bb462331fab4c1bf68 | L826 |
| slspirit | tiles | 6.u103 | LOAD32_BYTE | 0x000001 | 0x80000 | 0dda4489 | cfad31e58adf5aea51c528fb5d7a2f076e6cf0bf | L827 |
| slspirit | tiles | 7.u104 | LOAD32_BYTE | 0x000002 | 0x80000 | 6208cdc7 | 242a93db057b6c01f0031cc8fd33da76baf6c879 | L828 |
| slspirit | tiles | 8.u105 | LOAD32_BYTE | 0x000003 | 0x80000 | eb5f67a2 | 4f6bf3fde6df4bc878b882f4f52805963352ef35 | L829 |
| flagrall | maincpu | 11_u34.bin | LOAD16_BYTE | 0x000001 | 0x40000 | 24dd439d | 88857ad5ed69f29de86702dcc746d35b69b3b93d | L835 |
| flagrall | maincpu | 12_u35.bin | LOAD16_BYTE | 0x000000 | 0x40000 | 373b71a5 | be9ab93129e2ffd9bfe296c341dbdf47f1949ac7 | L836 |
| flagrall | oki1 | 13_su4.bin | LOAD | 0x000000 | 0x80000 | 7b0630b3 | c615e6630ffd12c122762751c25c249393bf7abd | L840 |
| flagrall | oki1 | 14_su6.bin | LOAD | 0x080000 | 0x40000 | 593b038f | b00dcf321fe541ee52c34b79e69c44f3d7a9cd7c | L841 |
| flagrall | sprites | 1_u5.bin | LOAD32_BYTE | 0x000000 | 0x80000 | 9377704b | ac516a8ba6d1a70086469504c2a46d47a1f4560b | L844 |
| flagrall | sprites | 5_u6.bin | LOAD32_BYTE | 0x000001 | 0x80000 | 1ac0bd0c | ab71bb84e61f5c7168601695f332a8d4a30d9948 | L845 |
| flagrall | sprites | 2_u7.bin | LOAD32_BYTE | 0x000002 | 0x80000 | 5f6db2b3 | 84caa019d3b75be30a14d19ccc2f28e5e94028bd | L846 |
| flagrall | sprites | 6_u8.bin | LOAD32_BYTE | 0x000003 | 0x80000 | 79e4643c | 274f2741f39c63e32f49c6a1a72ded1263bdcdaa | L847 |
| flagrall | sprites | 3_u58.bin | LOAD32_BYTE | 0x200000 | 0x40000 | c913df7d | 96e89ecb9e5f4d596d71d7ba35af7b2af4670342 | L849 |
| flagrall | sprites | 4_u59.bin | LOAD32_BYTE | 0x200001 | 0x40000 | cb192384 | 329b4c1a4dc388d9f4ce063f9a54cbf3b967682a | L850 |
| flagrall | sprites | 7_u60.bin | LOAD32_BYTE | 0x200002 | 0x40000 | f187a7bf | f4ce9ac9fe376250fe426de6ee404fc7841ef08a | L851 |
| flagrall | sprites | 8_u61.bin | LOAD32_BYTE | 0x200003 | 0x40000 | b73fa441 | a5a3533563070c870276ead5e2f9cb9aaba303cc | L852 |
| flagrall | tiles | 10_u102.bin | LOAD | 0x000000 | 0x80000 | b1fd3279 | 4a75581e13d43bef441ce81eae518c2f6bc1d5f8 | L855 |
| flagrall | tiles | 9_u103.bin | LOAD | 0x080000 | 0x80000 | 01e6d654 | 821d61a5b16f5cb76e2a805c8504db1ef38c3a48 | L856 |
