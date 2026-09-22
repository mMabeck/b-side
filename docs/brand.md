# Brand: name, icon, theme

## Name

**B-Side** — bundle `B-Side.app`, id `ai.syv.bside`.

A worktree app is a machine for second takes: every task is an alternate cut of
the same record, kept off the A-side until it's good. One syllable and a half,
spells itself, and the icon draws itself from it.

Alternatives, in order of preference:

| Name | Read |
| --- | --- |
| **B-Side** | alternate takes; fits the half-LP mark exactly |
| **Platter** | the thing the work spins on; neutral, no music baggage |
| **Groove** | parallel tracks cut side by side; slightly overused |
| **Sunside** | reads the icon as a rising sun, not a record |
| **Cut** | terse and git-adjacent, but too generic to search for |

## Icon

`assets/icon/` — a risograph half-LP rising out of a flat orange field, tonearm
dropping in from the top right. Only the top half of the disc is in frame; the
rest of the sheet is orange.

    assets/icon/icon.py        draws it (riso print simulator in ~/Claude/fun/riso)
    assets/icon/mask.py        insets the art into Apple's 824/1024 rounded-rect
    assets/icon/make-icns.sh   renders + packs AppIcon.icns
    assets/icon/icon.png       full-bleed 1024 artwork
    assets/icon/icon-plain.png same, no tonearm — cleaner at 16–32 px
    assets/icon/AppIcon.icns   the shipping icon

Regenerate with `assets/icon/make-icns.sh` (add `--no-arm` for the plain cut).
The render is seeded, so it reproduces exactly; `--seed` gives a different
grain, registration drift and groove wobble.

Rules: never redraw the mark flat — the grain, the off-register paper halo and
the halftone in the orange *are* the mark. Don't put type inside it. Don't
recolour the field; orange `#FF6C2F` is the brand.

## Theme

`assets/theme/b-side.conf` (dark) and `b-side-paper.conf` (light) are Ghostty
themes. The app derives its whole-window `DashPalette` from the active Ghostty
theme, so these files set both terminal and chrome colours.

| Role | Hex | Where |
| --- | --- | --- |
| Orange (brand) | `#FF6C2F` | cursor, running task, primary accent |
| Paper | `#F3EEE2` | light background, dark-mode foreground |
| Near-black | `#16141C` | dark background |
| Ink navy | `#26283E` | light foreground, tonearm |
| Pink | `#FF48B0` | selection highlight, label |
| Teal | `#00A995` | clean/passing state |
| Red | `#F03C3E` | conflict, failure |
| Yellow | `#FFE028` | dirty worktree, needs attention |

Install: copy into `~/.config/ghostty/themes/` as `b-side` / `b-side-paper` and
set `theme = b-side,light:b-side-paper`.
