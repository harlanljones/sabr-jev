# sabr-jev — Development Agent Guide

## Project intent

Sabr-Jev is a confidence-gated season-card workbench: Batter|Pitcher season
cards built from free public stats (Lahman-primary), rendered as precomputed
JSON state, gated by TypeSafe Jev Choice/Score/Noul with a **confidence
latch**. The product is the latch — without it the demo is a stat table.
Greenfield `harlanljones/sabr-jev`. Full spec: `docs/specs/PRD-sabr-jev.md`.

## Where to work

| Path | Purpose |
|---|---|
| `docs/specs/` | PRD, outline, merged sabermetrics notes — the approved spec set |
| `data/` | Frozen inputs incl. `woba_weights.csv` (Fangraphs Guts export, cited) |
| `lib/`, ETL (Makefile) | Lahman → SQLite/Parquet, stint-merge, cards |
| `assets/`, LiveView | Card UI, review lane, footer |

## Instruction precedence

1. This file.
2. `docs/specs/PRD-sabr-jev.md` (Conditionally approved v0.1.1).
3. `docs/specs/sabermetrics-jev-MERGED.md` and the outline for metric detail.

## Non-negotiable boundaries (from the PRD falsifiers)

- **No live Fangraphs/BBRef scrape.** Lahman + the committed
  `data/woba_weights.csv` only. wOBA missing a year → omit / mark
  `unavailable`.
- **Jev never computes numbers.** All math in code; Jev receives precomputed
  state JSON only. No chat generation, no chat writeup.
- **OPS+ is labeled "OPS+ (Sabr-Jev)"** everywhere (card + `/about`), with
  formula + Teams.BPF published. Never claim Fangraphs/BBRef parity.
- **Latch rules:** Choice/Score → act/review/escalate; **Noul → act/review
  only** (floor 0.5; escalate unreachable on Noul alone — the card escalates
  only if a Choice/Score does).
- **No deterministic Noul.** Min PA/IP sample gates live in code, never as a
  Jev question (`meets_min_sample` Noul is killed).
- **No T+1 leakage.** Next-season Noul uses an eval-only / clearly marked
  oracle join, never the judgment state for T.
- **Retrosheet notice iff Retrosheet data appears**; footer always cites
  Lahman and says "no Fangraphs scrape in v1".
- Count Gate stays parked. Not Skipper.

## Commands

Greenfield — commands land here only once verified by running them:

```bash
mix deps.get
mix test               # offline; recorded Jev fixtures, no TYPESAFE_API_KEY needed
mix format --check-formatted
```

## Data safety

- Offline CI by default: latch UI tests use recorded Jev fixtures. Anything
  needing `TYPESAFE_API_KEY` is a live check, never part of `mix test`.
- Never commit Lahman bulk data, live API keys, or `.env*`.
- Latch τ untuned → UI must label thresholds "provisional"; mini-labeled
  requires N≥30.

## Code style

Elixir + Phoenix LiveView. `mix format` is law (the formatter hook runs it).
Pure metric computation in small modules with ExUnit tests beside them.
Match surrounding code; comments explain why.

## Commits

Conventional Commits if a commit-msg hook enforces it (`chore: ...`), plain
imperative sentence otherwise. Squash-merge with PR number appended.

## Progress reporting

Report against PRD acceptance: cards real from Lahman + documented formulas;
≥1 Choice + ≥1 Score + (≥1 Noul or explicit skip when no T+1); latch real; no
invention; lineage real; not Count Gate / not Skipper.
