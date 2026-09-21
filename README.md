# Sabr-Jev — confidence-gated season-card workbench

Batter|Pitcher season cards from free public stats (Lahman-primary), rendered
as precomputed JSON state, gated by TypeSafe Jev Choice/Score/Noul with a
**confidence latch**. The product is the latch — without it the demo is a
stat table.

## Quick start

```sh
mix deps.get
mix test               # offline; recorded Jev fixtures, no TYPESAFE_API_KEY needed
mix format --check-formatted
mix phx.server         # workbench at http://localhost:4000, formulas at /about
```

Python ETL (standard library only):

```sh
make fetch             # pinned HTTPS inputs, first use only
make data              # offline rebuild into priv/data/cards.json
make test-data         # offline ETL + metric tests, no network
```

## How it fits together

- `scripts/` + `Makefile` → `priv/data/cards.json`: Lahman counts summed
  across stints before dividing; league context is league-year; frozen
  `data/woba_weights.csv` supplies wOBA weights (missing year → unavailable).
  Full contract in `docs/data.md`.
- `SabrJev.Catalog`: trusted card boundary. Every card served to judgments or
  the latch has exact outer keys, `id == role:player_id:year`, outer metrics
  equal to judgment-state metrics, and batter PA / pitcher IP equal to the
  sample value. Mutations are rejected before any Jev use.
- `SabrJev.Questions` / `SabrJev.Judgments`: frozen Choice/Score/Noul pack on
  precomputed state JSON only. Recordings in `priv/jev/recordings/` are
  immutable; `mix sabr.record` writes them (needs `TYPESAFE_API_KEY` or the
  local Jev key). Ten recordings ship: six 2024 cards with retrospective
  oracle Nouls plus the four qualified 2025 cards (Choice/Score only, no T+1).
- `SabrJev.Latch`: Choice/Score → act/review/escalate; Noul → act/review
  only (floor 0.5, escalate unreachable on Noul alone). Thresholds are
  provisional; insufficient sample cannot act.
- `SabrJevWeb.WorkbenchLive` (`/`) + `AboutLive` (`/about`): role toggle,
  player-season picker, headlines + shape, latch with full probabilities in
  review/escalate (no bold single recommendation there), clearly labeled
  retrospective oracle pane, evaluation status. No default dashboard styling:
  restrained scorebook/workbench with prominent confidence gating.
- `SabrJev.Prospective` / `SabrJev.Evaluation` (`mix sabr.capture`,
  `mix sabr.evaluate`): prospective enrollment with a conservative January 1
  cutoff and a local append-only hash-chained ledger that **cannot prove
  external capture time**. Status: infrastructure only, accuracy pending.
  Details in `docs/evaluation.md`.

## Non-negotiables

- No live Fangraphs/BBRef scrape. Lahman + committed `data/woba_weights.csv`.
- Jev never computes numbers; it receives precomputed state JSON only.
- **OPS+ (Sabr-Jev)** label everywhere, formula + Teams.BPF published.
- No deterministic Noul; minimums (200 PA / 50 IP) live in code.
- No T+1 leakage: oracle joins are eval-only, never judgment state.
- Footer cites Lahman and says “no Fangraphs scrape in v1”. No Retrosheet
  data in v1. Count Gate stays parked; not Skipper.
