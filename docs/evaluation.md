# Prospective evaluation

Status: infrastructure only. Prospective accuracy is pending, not claimed.

| Item | Value |
|---|---|
| Enrollable cohort | 2025 → 2026 (derived from frozen pins, not hand-set) |
| Cutoff | 2026-01-01T00:00:00Z (Jan 1 of the outcome season, stricter than opening day) |
| Cohort state today | **closed** — the window shut 2026-01-01; the 2026 → 2027 window opens when a 2026 source is pinned and closes 2027-01-01 |
| Recordings eligible today | 0 (the 48 committed recordings are retrospective or Choice/Score-only; the four 2025 ones carry no Noul and no mode) |
| Report status string | `"prospective, accuracy pending"` |
| Ledger guarantee | append-only, hash-chained — **cannot prove external capture time** |
| Threshold revision v2 | act 0.65 / review 0.45; Noul decoupled (no veto). Original 0.8/0.5 made act unreachable across recordings (max season_read conf 0.68, every act capped by the Noul-review veto). |
| Threshold revision v3 (current) | mean-aggregation: card route = mean Choice/Score confidence; act ≥ 0.65, review ≥ 0.45. Min-based bars left pitchers with zero acts across 23 pitcher recordings. Trade: a confident companion answer can carry a hesitant one; per-answer probabilities stay visible. Bars stay provisional; v4 awaits prospective outcomes. |
| Retrospective joins | seasons through 2024 only: a join is retrospective iff **both** its seasons are in the frozen pins |

## Cohort and cutoff

Cohort and baseline freeze in `SabrJev.Prospective.enroll/2` before any
capture. The enrollable cohort is **the newest season in the frozen source
pins** (`SabrJev.Prospective.enrollable_year/0`, currently
`latest_frozen_season` = 2025), and the cutoff is January 1 of that cohort's
outcome season (`cutoff_for/1`, currently `2026-01-01T00:00:00Z`). A test
asserts the window still matches `data/sources.json` and
`priv/data/cards.json` `provenance.latest_season`, so the window cannot drift
from the pins unnoticed.

The cohort is the newest pinned season rather than the season after it because
the season after it cannot have a card at all: the ETL writes
`provenance.latest_season` from the same manifest the pin mirrors, so the moment
a card for season *N+1* exists, the pin has moved to *N+1* and that card is
historical. Both halves of such a window are mutually exclusive, which made
capture impossible by construction. Taking the newest season keeps one season
per cohort, keeps every older season refused as `:historical_cohort`, and makes
the window open exactly when a new source is pinned.

Three states follow, all derived:

| State | Seasons | Meaning |
|---|---|---|
| Retrospective | through 2024 | both seasons are in the pins; plumbing and eval only, never validation |
| Window closed | 2025 | the cohort itself, after 2026-01-01; no capture is possible or honest |
| Enrollable | 2026 → 2027 | opens when a 2026 source is pinned; closes 2027-01-01 |

There is no clock override in production capture. `mix sabr.capture` requires an
explicit `--captured-at` and refuses historical cohort years, captures outside
the cohort window, duplicate captures, incomplete records, and any ledger whose
existing lines fail hash verification. `SabrJev.Prospective.window_open?/1` is a
pure function of the supplied instant, so the tasks and the UI never read the
wall clock and no test depends on the day it runs.

## Recording a prospective prediction

A prospective prediction judges a season whose outcome does not exist yet, so
its card carries no oracle marker. `mix sabr.record --prospective` asks the
frozen next-season Noul anyway — the same question id and wording as the
retrospective one, so the ledger's `noul_id` stays comparable across both — and
stamps `"mode": "prospective"` on the recording. The task refuses a prospective
recording for any card that is not the enrollable season or that already carries
a realized T+1 oracle.

Prospective recordings live in `priv/jev/recordings/prospective/`, never beside
the frozen retrospective ones: a card can legitimately have both, and neither
artifact may be mistaken for the other. A recording without a `mode` is treated
as retrospective and fails closed, so the 48 committed recordings validate
unchanged and can never be captured as predictions.

```sh
# 1. Record the prediction for the enrollable season (needs TYPESAFE_API_KEY).
mix sabr.record --prospective --card pitcher:example:2026

# 2. Freeze it before the outcome season (no clock default exists).
mix sabr.capture --catalog priv/data/cards.json --ledger tmp/ledger.jsonl \
  --baseline '{"batter":0.5,"pitcher":0.5}' --captured-at 2026-06-01T00:00:00Z

# 3. Score realized T+1 outcomes; the baseline must match the frozen ledger.
mix sabr.evaluate --ledger tmp/ledger.jsonl --outcomes tmp/outcomes.json \
  --report tmp/report.json --baseline '{"batter":0.5,"pitcher":0.5}'
```

Capture resolves each card's recording at
`priv/jev/recordings/prospective/<role>--<player_id>--<year>.json` and takes the
Noul probability from the recorded typed answer; it never recomputes a number. A
missing recording is a hard error naming the path to produce first, and a
recording whose mode is not `prospective` is refused, so capture cannot
substitute either an invented prediction or a judgment that was made with the
outcome already known. Because the current cohort window is closed, production
capture refuses every card in the frozen catalog today — as `:window_closed` for
2025 cards and `:historical_cohort` for everything else.

Capture refuses historical cohort years, captures outside the cohort window,
duplicate captures (including duplicates inside one invocation), state-hash
mismatches, probability values outside 0..1, and any ledger that fails
verification before or after the batch. Evaluate refuses a ledger that fails
verification, a `--baseline` that disagrees with the baseline frozen into the
ledger, a ledger that mixes cohort cutoffs, and any line whose mode is not
`prospective`. Neither task calls `DateTime.utc_now/0`.

### Evidence on hand

The prospective question set is exercised against the live API, not only against
fixtures. On 2026-09-22 two real recordings were produced with
`mix sabr.record --prospective` for the then-enrollable season and validated by
the same record contract the task enforces:

| Card | Noul answer | State hash | Questions hash |
|---|---|---|---|
| `batter:judgeaa01:2025` | 0.48 (`ops_plus_drop_ge_10_next`, conf 0.52) | `sha256:40e90fc8909925d62ca28fd115b92e433dfb8e7b72329a729a52e3493de376bf` | `sha256:4cfe7f0c4dcecfc997c46f2df329e9f3e5a96ce4752300f5996df857176d00d8` |
| `pitcher:skenepa01:2025` | 0.21 (`fip_rise_ge_0_50_next`, conf 0.79) | `sha256:917d779bc5813d7395a44309bcce3be3793249e817a9f4e53d49f94ed1cfad5c` | `sha256:6635e0fc7d7a314fe1ee266ca6b7bc25106117960acd8d26b54f7d6dcbb63667` |

Both were written to a scratch directory rather than to `priv/`: their cohort
window had already closed on 2026-01-01, so they can never be captured, and
`priv/jev/recordings/prospective/` is reserved for recordings made inside a
genuinely open window. The capture attempt over that real recording then quit
with `cannot capture batter:judgeaa01:2025: :window_closed`, which is the honest
end-to-end result for a closed cohort.

## Ledger limits

`mix sabr.capture --catalog PATH --ledger PATH --baseline JSON` appends one
hash-chained JSON line per card, keyed by `card_id`, `noul_id`, `probability`,
`mode`, `state_hash`, `questions_hash`, `model`, `captured_at`, `cutoff`,
`baseline`, `previous_hash`, and `line_hash`. Each line also carries its own
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
lines carry two different cohort `cutoff` values, or any line whose mode is not
`prospective`, is refused outright. Missing outcomes remain pending and
excluded, never negative labels. The report keeps Brier by role, baseline
Brier, reliability buckets, coverage, and missingness (with a `pending_rate`),
and it carries `status: "prospective, accuracy pending"`, `mode`, the cohort
`cutoff` **frozen into the ledger** (not the currently enrollable one),
`baseline`, and `ledger_limit` so no consumer has to infer the labeling rules.

## Retrospective plumbing

Historical 2024 → 2025 joins exercise plumbing only
(`SabrJev.Prospective.retrospective?/1`) and must remain labeled retrospective,
never prospective validation. The predicate is derived from the card's own
season and the pins: a join is retrospective iff both seasons are in the frozen
pins, so every card through 2024 is retrospective and the newest pinned season
is not. The tests assert that split over the whole artifact rather than over a
hand-written ID list.

## Baselines

Baselines must be frozen from development years only, or declared fixed before
predictions. Never fit a baseline on outcomes or the holdout. Losses ship
honestly with no accuracy guarantee, and no Choice/Score calibration claim
follows from Noul evaluation.