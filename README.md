# statusline-claude

A dense, colorful status line for [Claude Code](https://claude.com/claude-code).
One Bash script, no dependencies beyond `jq`. Truecolor gradient bars for context
usage and rate limits, a compact cost/velocity header, a monthly billing rollup,
and a "combo streak" that rewards heavy 5-hour blocks.

```
my-repo (main) $1.23 | +1240 -380 | Opus 4.8

ctx ██░░░░░░░░ 23%  790k    Skimming
5h  █████████░ 91%  01:00   Excellent x3
7d  █░░░░░░░░░ 12%  5d2h
$48.10 | +10867 -3279 | 16d22h
```

(In a real terminal the bars are an RGB green→gold→red gradient and the numbers
are color-coded.)

## What each line shows

**Header** — `repo (branch)` · session cost · session lines `+added -removed` · model.

**`ctx`** — context window fill. Gradient bar · `%` · **tokens remaining** ·
a mood word that escalates as the window fills (`Clueless` → `BrainFull`).

**`5h`** — the rolling 5-hour usage limit. Bar · `%` · **time the block resets** ·
combo word + multiplier (see below).

**`7d`** — the 7-day usage limit. Bar · `%` · **time until reset**.

**Totals** — current **billing month**: cost · lines `+/-` · time until the month
rolls over. (Not all-time — see [Billing cycle](#billing-cycle).)

### Column layout

The middle column (tokens / reset clock / reset countdown) is **center-aligned**:
each value's midpoint stacks on a shared axis. Monospace can't pad half a glyph,
so even/odd-length values wobble ≤0.5 char — that's a font-grid limit, not a bug.

### Combo streak

Hit ≥90% of a 5-hour block and you bank **+1 combo** (`x1`…`x10`), shown after the
`5h` word. Each 5-hour block is credited exactly once, even across concurrent
sessions (first render to atomically create the block's marker wins). No new credit
for 24h and the combo resets to 0. Purely cosmetic — a "you grinded today" badge.

## Requirements

- **Claude Code** (the status line API)
- **`jq`** — `brew install jq` / `apt install jq`
- **`git`** — for the repo/branch in the header
- A terminal with **truecolor** (24-bit) support for the gradients. Most modern
  terminals (iTerm2, Ghostty, WezTerm, kitty, recent Terminal.app) qualify.

Built and tested on macOS (BSD `date`/`stat`); includes GNU (`date -d`) fallbacks
for Linux.

## Install

1. Drop the script into your Claude config dir:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/nikita-mogilevskii/statusline-claude/main/statusline.sh \
     -o ~/.claude/statusline.sh
   ```

   (or clone the repo and copy `statusline.sh` to `~/.claude/`)

2. Point Claude Code at it. Add this block to `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh",
       "padding": 0
     }
   }
   ```

3. Start (or restart) Claude Code. The status line renders on the next turn.

No execute bit needed — it's invoked via `bash`.

## Where tracking data lives

The script keeps a little state so it can show **cross-session** and **monthly**
numbers. Everything is local, plain JSON, under `~/.claude/`. Nothing leaves your
machine, and none of it is in this repo.

| File / dir | Holds | Written |
|---|---|---|
| `~/.claude/statusline-costs.json` | per-session cost + lines added/removed, keyed by `session_id`. Totals are summed across sessions. | every render |
| `~/.claude/statusline-cycle.json` | billing-month anchor + baseline, so totals show the **current month** only. Archives finished months in `history[]`. | on month rollover |
| `~/.claude/statusline-combo.json` | combo `{level, last, block}` streak state. | when a block is credited / expires |
| `~/.claude/statusline-combo-blocks/` | one empty marker file per credited 5-hour block (the cross-session dedupe lock). Auto-pruned after ~11h. | when a block is credited |

### Billing cycle

"Totals" shows the **current calendar month**, not all-time. The anchor is the day
the cost DB was first written; each month from there is one cycle. On rollover the
finished month's delta is archived into `history[]`, the baseline resets to the
current all-time totals, and the displayed values become `all-time − baseline`.

### Reset / start fresh

```bash
# wipe cost + monthly history
rm ~/.claude/statusline-costs.json ~/.claude/statusline-cycle.json
# wipe the combo streak
rm ~/.claude/statusline-combo.json
rm -rf ~/.claude/statusline-combo-blocks
```

The files are recreated automatically on the next render.

## Customizing

A few knobs near the top / inline:

- `BAR_WIDTH` — width of the gradient bars (default `10`).
- `COL_A_W` — width of the centered value column (default `6`).
- `CULT_WORDS` — the ctx mood words, one per 10% tier.
- `COMBO_WORD` / `COMBO_R/G/B` — combo words and their per-tier colors.
- `COMBO_THRESHOLD` (default `90`) / `COMBO_TTL` (default `86400`s).

## License

MIT — see [LICENSE](LICENSE).
