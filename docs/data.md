# Reproducible season data — schema/formula version 1

| Item | Value |
|---|---|
| Artifact | `priv/data/cards.json` (`schema_version: 1`, 12 cards, byte-identical rebuilds) |
| Inputs | 4 Lahman tables (128598 / 57630 / 3614 / 24270 rows) + 155-season frozen wOBA weights |
| Latest season | 2025 · scope AL/NL · formula `sabr-jev-v1` |
| Recordings | 10 immutable (`priv/jev/recordings/`): 6 with retrospective oracle Noul, 4 qualified 2025 Choice/Score-only |
| License | Lahman CC-BY-SA-3.0 (SABR/Sean Lahman); weights are third-party constants, not project-owned |

## Commands (Python standard library only)

Run from the repository root with Python 3.10+ and Make:

```sh
make fetch                 # HTTPS only for absent, explicitly pinned inputs
make data                  # always offline, verifies every cached SHA-256
make test-data             # no network, no API credentials
make fetch FETCH_FLAGS=--offline   # verify cache without network
```

`make data` deliberately does **not** depend on `fetch`: offline rebuilds must
never silently make requests. First use requires `make fetch`. Cache corruption
fails closed, including in online fetch mode; inspect/remove the offending file
explicitly before fetching again. A download is checked before atomic publication.
Failures cannot replace an existing verified input with partial bytes.

Equivalent Python commands:

```sh
python3 -m scripts.etl fetch
python3 -m scripts.etl build --offline
python3 -m unittest discover -s tests -v
```

`PYTHON=python3.12` overrides the interpreter. `FETCH_FLAGS` passes fetch options;
`DATA_FLAGS` passes build options. Supported options:

| Flag | Default / behavior |
| --- | --- |
| `--manifest PATH` | `data/sources.json`, explicit immutable URLs, revisions, SHA-256s, row counts, latest season |
| `--raw-dir PATH` | `data/lahman/`, raw four CSVs |
| `--weights PATH` | `data/woba_weights.csv`, exact frozen bytes |
| `--database PATH` | `data/lahman/lahman.sqlite3` |
| `--output PATH` | `priv/data/cards.json` |
| `--selection PATH` | `data/catalog.json`, JSON object with `cards` selector array |
| `--select role:playerID:YYYY` | Repeatable; replaces default selection, not additive |
| `--offline` | Never request network; build enforces this even without the flag |

Example custom selection, without overwriting the app catalog:

```sh
make data DATA_FLAGS='--select batter:judgeaa01:2024 --select pitcher:skenepa01:2025 --output tmp/selected-cards.json --database tmp/selected.sqlite3'
```

The pure `scripts.etl.build_catalog(tables, weights_by_year, selection)` function
also supports arbitrary `(role, playerID, year)` selections. Only real AL/NL rows
present in the pinned source can be selected. Unknown IDs/roles/years fail, never
invent a player. Duplicate selectors deduplicate; duplicate source stints fail.
Older seasons with invalid counts may fail validation; missing core inputs remain
unavailable. The fixed default is **not** a moving latest-season query.

To update the source, supply/review a new explicit manifest with immutable URLs,
revision, checksum, row counts and latest season, fetch those pins, and deliberately
update selection/provenance. No implicit source discovery or live-stat scraping.

## Inputs, provenance and rights

The independently checked source note is [`data-sources.md`](data-sources.md).
The executable pin is [`../data/sources.json`](../data/sources.json); full URLs,
revisions, checksums and row counts are embedded unchanged in every catalog.

- Lahman mirror: Rdatasets revision
  `1dcc2bf5f955cc1224a3e1307256e1fe86b68dae`.
- Four source tables: Batting 128598 rows, Pitching 57630, Teams 3614,
  People 24270. Latest input season: **2025**.
- R-export columns `X2B`/`X3B` are doubles/triples. `rownames` is retained in
  SQLite as a source field, never treated as a baseball statistic.
- Attribution: **SABR, database donated by Sean Lahman**,
  [CC-BY-SA-3.0 Unported](https://creativecommons.org/licenses/by-sa/3.0/).
  [Official database notice](https://sabr.box.com/shared/static/qtgh1olzcaauz5x234wqx8huixizff8l.txt).
  Derived catalog data retain attribution and share-alike obligations. Rdatasets'
  software GPL license is not the database license.
- `data/woba_weights.csv` preserves the exact 155-season static mirror bytes,
  through 2025, SHA-256
  `21f9cb2e86d90c43e100f1a9e36c3feab8bcc6595c437849e8c4a4433b914ce6`.
  [Pinned mirror](https://raw.githubusercontent.com/stormlightlabs/baseball/a3e064e998b52570ad0f2c3ab6d4c5e12aa8d1f1/data/fangraphs/woba.csv),
  [mirror attribution](https://raw.githubusercontent.com/stormlightlabs/baseball/a3e064e998b52570ad0f2c3ab6d4c5e12aa8d1f1/web/src/routes/docs/attribution.md),
  attributed upstream to [Fangraphs Guts](https://www.fangraphs.com/tools/guts).
  **This verifies a static mirror, not parity with today's live table. The
  mirror's MPL software license does not establish a separate upstream data
  license. These third-party constants are not project-owned.** The PRD permits
  the cited frozen constants. Never use the file's `cFIP` column; derive cFIP from
  Lahman pitching counts instead.

**No Fangraphs scrape in v1. No live Fangraphs or Baseball-Reference requests.**
No Retrosheet input is used. `fetch` contacts only the manifest's pinned HTTPS
CSV URLs. Attribution links are documentation, not ETL requests.

## Storage and reproducibility

Raw CSVs and the SQLite database are local under ignored `data/lahman/`; do not
commit them. The frozen weights, manifest, selection and small derived catalog
belong in version control. All source rows are stored, including historical and
non-AL/NL data; only selected-year AL/NL rows feed v1 metrics.

SQLite schema (`PRAGMA user_version=1`):

- `Batting`, `Pitching`, `Teams`, `People`: original CSV columns as SQLite TEXT,
  preserving empty/unknown values and original export names. SQL consumers must
  explicitly cast counts and must not mistake blanks for measured zeroes.
- Batting/Pitching indexes `(playerID,yearID)` and `(lgID,yearID)`.
- Unique Teams `(yearID,teamID)` and People `(playerID)` indexes.
- `metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)` stores each provenance
  field as JSON. No build timestamp is injected.
- `cards(id TEXT PRIMARY KEY,role TEXT NOT NULL,player_id TEXT NOT NULL,
  year INTEGER NOT NULL,payload TEXT NOT NULL)` stores the exact card object as
  JSON, indexed additionally on `(player_id,year)`.

The build validates inputs, computes cards, creates a fresh SQLite file, checks
integrity, then atomically replaces each output file. JSON uses sorted object keys,
sorted card IDs, sorted warnings, UTF-8, two-space indentation and a final newline.
Floating-point metrics are not rounded. Repeated offline builds are byte-identical
for JSON and, on the same SQLite runtime, for SQLite. Cross-SQLite-version physical
file identity is not promised. A failure between publishing the two output files
can leave them at different generations; rebuild both together after interruption.

## Counting and formulas (`formula_version = "sabr-jev-v1"`)

Sum counts across player-season stints **before** dividing. League baselines sum
**all AL/NL players' counts** for that year/league, before sample filtering. They
are not means of player rates. A traded player uses stint PA-weighted batting
league/park context, or stint outs-weighted pitching cFIP. No next-season field
participates in any current-season formula.

Counts must be nonnegative finite integers. Invalid AB/H/BB/SO or inconsistent
known counts fail the build: H+SO cannot exceed AB, extra-base hits cannot exceed
H, IBB cannot exceed BB; pitcher known SO+BB+HBP+HR cannot exceed known BFP, and
HR cannot exceed H when H is present. Validate each stint, not just its total.
Missing HBP, SF or IBB is assumed zero **with a warning**. Other missing core
inputs (including SH and BFP) propagate null to dependent metrics, with a warning;
other independently computable metrics remain available. No denominator <= 0
produces a rate. JSON uses null, never NaN/Infinity. Missing Teams.BPF leaves OPS+
unavailable rather than assuming a neutral park. League missing-data warnings
are propagated to affected cards.

### Batters

```text
1B = H - X2B - X3B - HR
TB = 1B + 2*X2B + 3*X3B + 4*HR
PA = AB + BB + HBP + SF + SH
OBP = (H + BB + HBP) / (AB + BB + HBP + SF)
SLG = TB / AB
OPS = OBP + SLG
ISO = (TB - H) / AB
BABIP = (H - HR) / (AB - SO - HR + SF)
BB% = BB / PA
K% = SO / PA
wOBA = (wBB*(BB-IBB) + wHBP*HBP + w1B*1B + w2B*X2B
        + w3B*X3B + wHR*HR) / (AB + BB - IBB + HBP + SF)
```

wOBA uses **exact-season weights only**. Missing year => null plus
`wOBA weights unavailable`; no nearest-year or generic constants.

### OPS+ (Sabr-Jev)

The UI must display the exact custom label **OPS+ (Sabr-Jev)**, not imply
Fangraphs/Baseball-Reference parity. Freeze this recipe:

```text
weighted_lg_OBP = sum(stint_PA * stint_league_OBP) / total_PA
weighted_lg_SLG = sum(stint_PA * stint_league_SLG) / total_PA
weighted_Teams_BPF = sum(stint_PA * Teams[year,team].BPF) / total_PA
park_adjustment = (1 + weighted_Teams_BPF/100) / 2
OPS+ (Sabr-Jev) = 100 * (OBP/(weighted_lg_OBP*park_adjustment)
                        + SLG/(weighted_lg_SLG*park_adjustment) - 1)
```

Teams.BPF is Lahman's batting park factor. A 100 BPF means neutral in this
custom half-schedule adjustment. This is a transparent recipe, not an assertion
that any vendor uses the same weighting or park treatment.

### Pitchers

Definition reference: [Fangraphs Sabermetrics Library — FIP](https://library.fangraphs.com/pitching/fip/).
This is a formula citation, not a statistics feed; the pipeline never requests it.

```text
IP = IPouts / 3                    # decimal innings, not baseball .1/.2 notation
ERA = 27 * ER / IPouts
component = (13*HR + 3*(BB+HBP) - 2*SO) / IP
league_cFIP = league_ERA - league_component
weighted_cFIP = sum(stint_IPouts * stint_league_cFIP) / total_IPouts
FIP = component + weighted_cFIP
K-BB% = (SO-BB) / BFP
HR/9 = 27*HR / IPouts
BB/9 = 27*BB / IPouts
K/9 = 27*SO / IPouts
```

League ERA/component are from summed Lahman counts, not rounded source ERA.
Missing BFP makes K-BB% null; it does not invent batters faced or invalidate FIP.

## Frozen JSON contract (`schema_version = 1`)

`priv/data/cards.json` is exactly an object with these keys:

| Key | Type / meaning |
| --- | --- |
| `schema_version` | integer `1` |
| `provenance` | object described below |
| `cards` | array of card objects, sorted by `id` |

Provenance fields: `manifest_sha256` (hex string), `sources` (the manifest's
Batting/Pitching/Teams/People objects, each with `url`, `revision`, `sha256`, `rows`),
`weights` (manifest's frozen-weight provenance with the same source fields and
`attribution_url`, `upstream_attribution`, `license_caveat`), `latest_season`
(integer), `license`, `license_url`, `notice_url`, `formula_version`, `scope`,
`purpose`, and `oracle_policy` (strings). No wall-clock build field.

Each card has **exactly**:

| Key | Type / meaning |
| --- | --- |
| `id` | string `batter:<playerID>:<year>` or `pitcher:<playerID>:<year>` |
| `role` | `"batter"` or `"pitcher"` |
| `player_id` | source playerID string |
| `player_name` | People nameFirst + nameLast |
| `year` | integer current season T |
| `metrics` | role-specific object; numeric or null values only |
| `sample` | `{qualified: boolean, minimum: 200 or 50, value: number or null, unit: "PA" or "IP"}` |
| `warnings` | array of strings, deterministic order |
| `judgment_state` | allowlisted object below; the only object intended for Jev |
| `oracle` | null, or eval-only retrospective object below |

Batter metrics have exactly these lower-snake-case keys:
`pa`, `obp`, `slg`, `ops`, `iso`, `babip`, `bb_pct`, `k_pct`, `woba`, `ops_plus`,
`league_obp`, `league_slg`, `park_adjustment`.

Pitcher metrics have exactly:
`ip`, `era`, `fip`, `k_bb_pct`, `hr_per_9`, `bb_per_9`, `k_per_9`, `league_cfip`.

All percentage metrics are fractions (e.g. 0.25, not 25). Count/sample values are
numbers, rate values are unrounded finite numbers or null. For a missing sample,
`value` is null and `qualified` is false. Batter threshold is PA >= 200; pitcher
threshold is IP >= 50. These deterministic gates live in code, never a Noul.

Judgment state has **exactly**:

```text
{
  role: "batter" | "pitcher",
  metrics: {the allowlisted role-specific numeric/null metric keys above},
  sample: {minimum: 200 | 50, value: number | null}
}
```

It contains no ID, player name, season/year, free-text warnings, oracle, outcomes,
T+1 values, or next-season fields. It is constructed from a positive allowlist,
not by deleting a few fields from a card. `role` is the only string. `sample`
contains numeric context only; no copied gate answer or unit string. Jev receives
already-computed numbers and never performs metric arithmetic.

An oracle, when available, has **exactly**:

```text
{
  year: T+1,
  metric: "ops_plus" | "fip",
  value: next-season metric number,
  label: boolean,
  target: "ops_plus_drop_ge_10_next" | "fip_rise_ge_0_50_next"
}
```

Batter label is `(OPS+ at T - OPS+ at T+1) >= 10`; pitcher label is
`(FIP at T+1 - FIP at T) >= 0.50`. Require a real next-year row, an available target
metric, and **both seasons meeting the same minimum sample**. Otherwise oracle
is null. A current underqualified sample never earns an oracle just because the
next sample is large. Never send the outer card/oracle to Jev. Oracle joining does
not change judgment state, even if next-season counts are changed.

## Demonstration selection and prospective limits

`data/catalog.json` selects twelve real cards: six of each role across 2024/2025.
Names and IDs were checked in the pinned CSVs. Arozarena 2024 merges TBA/SEA;
Gregory Soto 2024 merges PHI/NL and BAL/AL, exercising cross-league cFIP weighting.
Mike Trout 2024 (126 PA) and Jacob deGrom 2024 (32 outs / 3 IP) demonstrate
underqualified samples. This deliberately chosen catalog is **not an evaluation
holdout** and establishes no model accuracy claim.

2024 -> 2025 oracle joins are retrospective plumbing only. Every 2025 card has
oracle null because these pins contain no 2026 season. As of the project's
2026-09-18 local-date review, 2026 is already underway: 2025 -> 2026 is **not**
prospective-eligible. Null oracle is not proof of prospective eligibility. A later
capture subsystem must apply its own conservative cutoff and cannot backdate.

## Verification

`make test-data` runs pure synthetic counting-row tests, frozen catalog/weights
checks, checksum rejection and no-network cache tests, state/oracle separation,
missing-data and zero-denominator cases. If local SQLite exists it additionally
checks every real catalog metric and available oracle against independently
aggregated SQL counts, reads back table counts/indexes/payloads, checks SQLite
integrity, and rebuilds into a temporary directory to verify byte identity.
Those three integration tests explicitly skip when bulk data is absent; the
remaining tests stay offline and exercise the committed small artifact. Full
verification is `make fetch data test-data`.
