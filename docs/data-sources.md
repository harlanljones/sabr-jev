# Verified frozen input candidates

Parent independently downloaded every CSV below and verified the listed SHA-256 against the research result. No live Fangraphs or Baseball-Reference request was made.

## Lahman

Rdatasets mirror revision: `1dcc2bf5f955cc1224a3e1307256e1fe86b68dae`.
URL prefix: https://raw.githubusercontent.com/vincentarelbundock/Rdatasets/1dcc2bf5f955cc1224a3e1307256e1fe86b68dae/csv/Lahman/

| File | SHA-256 | Parsed rows |
| --- | --- | --- |
| Batting.csv | a4083e2d4bacf411c352686fd7c0696eaa4bc8719b718db5e9c45ac90fd95b35 | 128598 |
| Pitching.csv | 6c45460dabbe2384b6ede22958c03f4881c0a7f249f30f02be92ce23a24d3ba8 | 57630 |
| Teams.csv | 9d1c390df5d2a422175f6bcfb56d099cfb9c5805586ba5e3f8c895a9952423ad | 3614 |
| People.csv | 33aacfdea45b8e19166e4d725191ac6b874b334260584d2999107b42cc746a81 | 24270 |

Latest season: 2025. R export adds `rownames`; doubles/triples are `X2B`/`X3B`. AL/NL scope for v0. League totals must use all rows before sample filters. Bulk CSVs stay local/ignored.

Lahman database attribution/license: SABR, donated by Sean Lahman; CC-BY-SA-3.0 Unported. Official notice: https://sabr.box.com/shared/static/qtgh1olzcaauz5x234wqx8huixizff8l.txt . License: https://creativecommons.org/licenses/by-sa/3.0/ . Do not confuse Rdatasets code GPL licensing with the database license. Preserve attribution/share-alike for derived data.

## Frozen wOBA constants

URL: https://raw.githubusercontent.com/stormlightlabs/baseball/a3e064e998b52570ad0f2c3ab6d4c5e12aa8d1f1/data/fangraphs/woba.csv
SHA-256: `21f9cb2e86d90c43e100f1a9e36c3feab8bcc6595c437849e8c4a4433b914ce6`.
155 seasons through 2025. Columns include Season,wOBA,wOBAScale,wBB,wHBP,w1B,w2B,w3B,wHR,runSB,runCS,R/PA,R/W,cFIP.
Mirror attribution: https://raw.githubusercontent.com/stormlightlabs/baseball/a3e064e998b52570ad0f2c3ab6d4c5e12aa8d1f1/web/src/routes/docs/attribution.md . It cites https://www.fangraphs.com/tools/guts . This verifies a static mirror, not parity with today's live table. PRD explicitly permits committing cited frozen constants; the mirror's MPL software license does not establish a separate upstream data license. Record that caveat; do not relabel third-party constants as project-owned. Never use this file's cFIP: derive league cFIP from Lahman.

## Prospective availability

System clock at verification: 2026-09-19 UTC. Latest complete input season is 2025; its next season is already underway. Thus no current completed input cohort meets the approved prospective cutoff. Capture must refuse it. The first potentially enrollable cohort is 2026 -> 2027, conditional on a completed 2026 source becoming available before the conservative 2027-01-01 cutoff. If that window is missed, wait for a later eligible cohort rather than backdating. Historical 2024 -> 2025 records may exercise plumbing but must remain labeled retrospective, never prospective validation.
