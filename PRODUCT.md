# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: baseball fans exploring famous recent seasons through a model's eyes,
and analysts who want the metrics and probabilities behind each read. One
surface serves both: story hook up top, numbers one click down.

## Product Purpose

Sabr-Jev turns Lahman season stats into Batter|Pitcher cards graded by typed
TypeSafe Jev judgments behind a confidence latch (act / review / escalate).
The new storyline surface lets visitors pick an interesting real-life season
and explore how the model would have reacted to it — verdict first, full
probabilities and audit trail underneath. Success means a fan grasps the
verdict in seconds and an analyst can verify it in one click.

## Positioning

A second opinion you can audit: precomputed numbers in, typed judgments out,
frozen state hashes, provisional thresholds labeled as provisional, and no
single bold claim under review or escalation. Neighboring stat pages show
numbers; this one renders a checkable verdict.

## Operating Context

Frozen Lahman inputs (latest season 2025) plus a static wOBA weights file;
no live scraper. Fifty cards and 48 recordings ship today; the storyline
surface draws seasons from 2020–2025 present in the pinned source. Oracle
(T+1) joins are retrospective eval-only panes, never judgment input. The newest
pinned season (2025) has no T+1 yet: it is the enrollable prospective cohort,
and its window closed 2026-01-01.

## Capabilities and Constraints

- Expanding the demo catalog requires new ETL selections and new immutable
  Jev recordings; nothing on the surface may invent a judgment.
- Latch rules are frozen: Choice/Score act/review/escalate, Noul
  act/review only, underqualified samples never act, thresholds provisional.
- OPS+ is always labeled "OPS+ (Sabr-Jev)"; footer cites Lahman and states
  no Fangraphs scrape in v1.
- Deliverable for this round: the live workbench, storylines, backtest and about
  surfaces, all reading frozen artifacts; prospective capture is CLI-only and
  makes no accuracy claim.

## Brand Commitments

Scorebook/workbench identity: restrained, ruled panels, tabular numerals,
confidence gating as the most prominent element. Existing name Sabr-Jev.

## Evidence on Hand

- Live workbench at `/` and formulas at `/about`; 50 cards in
  `priv/data/cards.json`; 48 recordings in `priv/jev/recordings/` (plus the
  separate `priv/jev/recordings/prospective/` for cohort-window predictions).
- Pinned source CSVs under `data/lahman/` (ignored bulk) for verifying
  player-season availability.
- State absences: no screenshots, no testimonials, no benchmarks beyond the
  recorded suite; mockups must not fabricate judgments or outcomes.

## Product Principles

1. Verdict first, workings one click down.
2. Never invent: every read traces to a frozen card and recording.
3. Small samples and weak signals get honesty, not hype.
4. One surface, two depths: fans get story, analysts get proof.
