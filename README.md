# Sabr-Jev — confidence-gated season-card workbench

[![Elixir](https://img.shields.io/badge/elixir-%3A~%3E1.20-purple)](https://elixir-lang.org)
[![Phoenix LiveView](https://img.shields.io/badge/phoenix-liveview-orange)](https://www.phoenixframework.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![No live scrape](https://img.shields.io/badge/scrape-none-lightgrey)](#non-negotiables)

Batter|Pitcher season cards from free public stats, graded by typed TypeSafe Jev
judgments behind a **confidence latch**. Season stats lie by omission — a hot
OPS hides a lucky BABIP, a shiny ERA hides a bad FIP. Sabr-Jev's value is the
verdict on the numbers: **act** on the read, **review** the full
probabilities, or **escalate** when the signal isn't there. Small samples can
never act, borderline calls never get a bold claim, and every judgment shows
its work. Without the latch this is a stat table; with it, it's a second
opinion you can audit.

Use it to sanity-check a breakout season before buying in, to flag regression
risk while there is still time to act on it, or as a reusable pattern for
putting any AI judgment behind fail-closed types, frozen state hashes, and a
prospective evaluation protocol instead of vibes.

## Results

Thirty-two real cards from pinned Lahman inputs; thirty immutable Jev
recordings; every latch route computed from frozen artifacts, never invented.
Explore them as stories at `/storylines`, or card by card in the workbench.

| Slice | Detail |
|---|---|
| Cards | 32 (16 batter, 16 pitcher, seasons 2021–2025) |
| Recordings | 30 (25 with retrospective oracle Noul; 2025s Choice/Score-only; Strider 2023 has no oracle — 7 outs in 2024) |
| Unrecorded | Trout 2024, deGrom 2024 (underqualified demos — honest empty states) |
| Routes | 10 review · 18 escalate · 0 act — the model is a skeptic; every call shows full probabilities |

| Check | Result |
|---|---|
| Offline Elixir suite (`mix test`, no API key) | 97 passed |
| Python ETL + metric suite | 23 passed |
| `mix format --check-formatted`, `mix compile --warnings-as-errors` | clean |
| ETL rebuild of `priv/data/cards.json` | byte-identical |
| Live `/`, `/storylines`, `/about` | 200, content-checked |
| Prospective accuracy | **pending by design** — infrastructure only, first enrollable cohort 2026→2027 |
| Latch thresholds | **provisional** (N=30 recordings, labeled minimum N≥30 for tuning — data exists, tuning does not) |

## Use cases

| Who | Flow |
|---|---|
| Fan / analyst | Pick Batter\|Pitcher → player-season → read the card; the latch banner tells you whether the Jev read is actable, worth review, or escalated — with full probabilities, never a single bold claim under review |
| Story explorer | Start at `/storylines`: twenty famous 2021–2025 seasons with hook lines and real verdict chips, filtered by breakout/regression lenses, deep-linked into the workbench |
| Developer | `SabrJev.Catalog` is the trusted boundary: exact keys, `id == role:player_id:year`, outer metrics == judgment-state metrics, PA/IP == sample value — mutations rejected before any Jev use |
| Researcher | Prospective pair (`mix sabr.capture` / `mix sabr.evaluate`) freezes predictions before the outcome season under a Jan-1 cutoff; Brier by role, baselines, reliability buckets, pending-not-negative outcomes |

## Design

```mermaid
flowchart LR
    Lahman[(Lahman CSVs\npinned + checksummed)] --> ETL[Makefile ETL\nsum counts, then rates]
    WOBA[data/woba_weights.csv\nfrozen constants] --> ETL
    ETL --> Cards[priv/data/cards.json\n12 cards + provenance]
    Cards --> Catalog[SabrJev.Catalog\ntrusted boundary]
    Rec[priv/jev/recordings/\n10 immutable judgments] --> Judg[SabrJev.Judgments\nvalidate only]
    Catalog --> Judg
    Judg --> Latch[SabrJev.Latch\nact / review / escalate]
    Catalog --> UI[WorkbenchLive / + StorylinesLive + AboutLive]
    Latch --> UI
```

```mermaid
flowchart TD
    A[Validated answers] --> B{Answer type}
    B -->|Choice / Score| C{confidence}
    C -->|≥ 0.8| ACT[act]
    C -->|≥ 0.5| REV[review]
    C -->|else, or 'other'| ESC[escalate]
    B -->|Noul: max p, 1-p| D{confidence}
    D -->|≥ 0.85| ACT
    D -->|else| REV
    E[Sample gate in code] -->|underqualified| REV
    style ACT fill:#dde5d3
    style REV fill:#efe6c8
    style ESC fill:#e8cfc8
```

Headlines are Lahman-feasible only: batter **OPS+ (Sabr-Jev)** + wOBA with ISO/BB%/K%/BABIP/PA shape; pitcher **FIP** + ERA + **K-BB%** with IP/HR-BB-K-per-9 shape. Jev receives precomputed numbers and never computes. Formulas, provenance, and counting rules: [`docs/data.md`](docs/data.md). Prospective protocol: [`docs/evaluation.md`](docs/evaluation.md). Input pins: [`docs/data-sources.md`](docs/data-sources.md).

## Quick start

```sh
mix deps.get
mix test               # offline; recorded fixtures, no key needed
mix phx.server         # workbench :4000, formulas /about
make fetch data test-data   # ETL: pinned fetch, offline rebuild, offline tests
mix sabr.record --card batter:judgeaa01:2024   # live Jev (needs key)
```

## Non-negotiables

- No live Fangraphs/BBRef scrape — Lahman + committed weights file only.
- Jev never computes numbers; precomputed state JSON in, typed answers out.
- **OPS+ (Sabr-Jev)** label everywhere; no vendor-parity claim.
- No deterministic Noul; minimums (200 PA / 50 IP) live in code.
- No T+1 leakage: oracle joins are eval-only, never judgment state.
- Footer cites Lahman and says “no Fangraphs scrape in v1”. No Retrosheet
  data in v1. Count Gate stays parked; not Skipper.

## Demo deployment (Fly.io)

```sh
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)   # once; only secret needed
fly deploy                                              # builds Dockerfile, serves :4000
```

The image bakes in the frozen cards + recordings, so the instance needs no
API key and performs no live inference. Prospective ledger writes land in
`tmp/` and are ephemeral across restarts — mount a volume at `/data` if
capture demos must persist.
- Footer cites Lahman, “no Fangraphs scrape in v1”. No Retrosheet data in v1. Count Gate parked; not Skipper.

## License

Code: [MIT](LICENSE). Data: Lahman database, SABR via Sean Lahman, [CC-BY-SA-3.0](https://creativecommons.org/licenses/by-sa/3.0/) — attribution and share-alike apply to derived data. wOBA weights are third-party frozen constants, not project-owned; see [`docs/data-sources.md`](docs/data-sources.md).
