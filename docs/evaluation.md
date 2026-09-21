# Prospective evaluation

Status: infrastructure only. Prospective accuracy is pending, not claimed.

| Item | Value |
|---|---|
| Enrollable cohort | 2026 → 2027 (derived from frozen pins, not hand-set) || Cutoff | 2027-01-01T00:00:00Z (Jan 1 of outcome season, stricter than opening day) |
| Recordings eligible today | 0 (all 10 recordings are 2024/2025; capture refuses them as historical) |
| Report status string | `"prospective, accuracy pending"` |
| Ledger guarantee | append-only, hash-chained — **cannot prove external capture time** |
| Threshold revision v2 | act 0.65 / review 0.45; Noul decoupled (no veto). Original 0.8/0.5 made act unreachable across 35 recordings (max season_read conf 0.68, every act capped by the Noul-review veto). Bars stay provisional; v3 tuning waits on prospective outcomes. |
| Historical 2024 → 2025 joins | retrospective plumbing only, never validation |

## Cohort and cutoff

Cohort and baseline freeze in `SabrJev.Prospective.enroll/2` before any
capture. The enrollable window is derived, not hand-set: the single cycle
after the latest season in the frozen source pins
(`SabrJev.Prospective.enrollable_year/0`, currently 2025 + 1 = 2026), and the
cutoff is January 1 of that cohort's outcome season
(`cutoff_for/1`, currently `2027-01-01T00:00:00Z`). A test asserts the window
still matches `data/sources.json` and `priv/data/cards.json`
`provenance.latest_season`, so the window cannot drift from the pins unnoticed.

There is no clock override in production capture. `mix sabr.capture` requires an
explicit `--captured-at` and refuses historical cohort years, duplicate
captures, incomplete records, and any ledger whose existing lines fail hash
verification.

System clock at the 2026-09-19 review: latest complete input season is 2025 and
its next season is already underway, so no current completed input cohort is
prospective-eligible. The first potentially enrollable cohort is 2026 -> 2027,
conditional on a completed 2026 source before the cutoff.

## Commands

`mix sabr.capture` and `mix sabr.evaluate` are the prospective pair. Capture
takes its predictions from immutable Jev recordings, not from new inference:

```sh
# 1. Record the judgment for the card first (needs TYPESAFE_API_KEY).
mix sabr.record --card pitcher:example:2026

# 2. Freeze it before the outcome season (no clock default exists).
mix sabr.capture --catalog priv/data/cards.json --ledger tmp/ledger.jsonl \
  --baseline '{"batter":0.5,"pitcher":0.5}' --captured-at 2026-06-01T00:00:00Z

# 3. Score realized T+1 outcomes; the baseline must match the frozen ledger.
mix sabr.evaluate --ledger tmp/ledger.jsonl --outcomes tmp/outcomes.json \
  --report tmp/report.json --baseline '{"batter":0.5,"pitcher":0.5}'
```

Capture resolves each card's recording at
`priv/jev/recordings/<role>--<player_id>--<year>.json` and takes the Noul
probability from the recorded typed answer; it never recomputes a number. A
missing recording is a hard error naming the path to produce first, so capture
cannot substitute an invented prediction. Because the enrolled cohort is
2026 -> 2027, no eligible recording exists yet and production capture is
expected to refuse every current card until 2026 judgments are recorded.

Capture refuses historical cohort years, duplicate captures (including
duplicates inside one invocation), state-hash mismatches, probability values
outside 0..1, and any ledger that fails verification before or after the batch.
Evaluate refuses a ledger that fails verification, a `--baseline` that
disagrees with the baseline frozen into the ledger, and a ledger that mixes
cohort cutoffs. Neither task calls `DateTime.utc_now/0`.

## Ledger limits

`mix sabr.capture --catalog PATH --ledger PATH --baseline JSON` appends one
hash-chained JSON line per card, keyed by `card_id`, `noul_id`, `probability`,
`state_hash`, `questions_hash`, `model`, `captured_at`, `cutoff`, `baseline`,
`previous_hash`, and `line_hash`. Each line also carries its own
`ledger_limit` field so the limitation travels with the data.

`SabrJev.Prospective.verify/1` recomputes every `line_hash` from its
predecessor, so it detects any edit, duplication, or reordering **within** the
lines it is given. It cannot detect a replaced or truncated ledger: a local
writer can always rewrite a shorter self-consistent chain, and `verify([])`
returns `:ok` by definition. A line whose `line_hash` is missing or
non-binary is refused as tampered, never crashed on. The local ledger is
append-only and hash chained, but it cannot establish a trusted external
timestamp because a local writer controls both the file and its clock. State
this limitation wherever a ledger is shown.

Writes are whole-file read-modify-write, so two concurrent captures can drop
the loser's lines while the surviving chain still verifies. Run capture
serially.

## Scoring

`mix sabr.evaluate --ledger PATH --outcomes PATH --report PATH --baseline JSON`
requires matching realized T+1 years, non-empty source provenance carrying a
`card_artifact`, a `target` equal to the captured `noul_id`, and a capture time
that itself precedes the outcome season: a line with a missing, unparseable, or
post-cutoff `captured_at` is refused, so scoring cannot launder a late capture
that the chain accepted. Every scored role must have a frozen baseline; a
missing role baseline is an error, never a silent 0.5 default. A ledger whose
lines carry two different cohort `cutoff` values is refused outright. Missing
outcomes remain pending and excluded, never negative labels. The report keeps
Brier by role, baseline Brier, reliability buckets, coverage, and missingness
(with a `pending_rate`), and it carries `status: "prospective, accuracy
pending"`, `mode`, `cutoff`, `baseline`, and `ledger_limit` so no consumer has
to infer the labeling rules.

Historical 2024 -> 2025 joins exercise plumbing only
(`SabrJev.Prospective.retrospective?/1`) and must remain labeled
retrospective, never prospective validation. The predicate is derived from the
card's own season, so every card in the frozen demonstration catalog
(`priv/data/cards.json`) reports `true`; the tests assert that over the whole
artifact rather than a hand-written ID list.

## Baselines

Baselines must be frozen from development years only, or declared fixed before
predictions. Never fit a baseline on outcomes or the holdout. Losses ship
honestly with no accuracy guarantee, and no Choice/Score calibration claim
follows from Noul evaluation.
