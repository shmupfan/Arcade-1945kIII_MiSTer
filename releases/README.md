# Releases

Released bitstreams and MRA files, in the MiSTer-devel arcade layout.

Copy `Arcade-1945kIII_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`, the
MRA files to `/media/fat/_Arcade/`, and the ROM sets (MAME 0.288/0.289
naming) to `/media/fat/games/mame/`.

Alternative versions live in `_alternatives/_1945k III/` and are copied
to `/media/fat/_Arcade/_alternatives/_1945k III/`.

| File | md5 | Notes |
|------|-----|-------|
| `Arcade-1945kIII_20261004.rbf` | `a19de473462e322cbdbd3a9d596bbc8d` | First release: 1945k III (four sets), Solite Spirits, '96 Flag Rally. |

Every released RBF passed, in order: frame replay against MAME for every
set (video pixel-exact), full-system boots against MAME from power-on, a
sound comparison against MAME, a board-level simulation through the MRA
stream and the SDRAM model, a clean Quartus timing summary (every clock
non-negative), and an md5-verified deploy.
