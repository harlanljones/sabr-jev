# Gates: Sabr-Jev first build

Scope: Approved working thin slice with prospective infrastructure; future accuracy pending.

- [x] G1: All offline Elixir application and latch tests pass without API key.
  CHECK: env -u TYPESAFE_API_KEY mix test && printf 'OFFLINE_TESTS_PASS\n'
  EXPECT: OFFLINE_TESTS_PASS
  EVIDENCE: 133 tests, 0 failures (env -u TYPESAFE_API_KEY mix test). Python ETL suite 23/23 OK.
- [x] G2: ETL and metric tests pass.
  CHECK: python3 -m unittest discover -s tests -v
  EXPECT: OK
  EVIDENCE: 23 tests OK.
- [x] G3: Elixir formatting and strict compilation pass.
  CHECK: mix format --check-formatted && mix compile --warnings-as-errors && printf 'BUILD_PASS\n'
  EXPECT: BUILD_PASS
  EVIDENCE: Both exit 0.
- [x] G4: Real source lineage, recorded Jev responses, and recomputed cards verified.
  CHECK: mix test test/sabr_jev/record_task_test.exs
  EXPECT: recordings validate against frozen catalog; state_hash matches
  EVIDENCE: 48 real recordings (43 with retrospective oracle Noul + 4 qualified 2025 Choice/Score-only + Strider 2023 without oracle) validate with correct state_hash against cards.json; catalog provenance has manifest_sha256 + per-source sha256 + license. Latch v3: mean-aggregated act 0.65/review 0.45, Noul decoupled; revisions documented in docs/evaluation.md with distribution analysis. Backtest view (/backtest) scores 43 recorded Noul predictions against realized outcomes, labeled retrospective.
- [x] G5: Live HTTP/LiveView workbench, review probabilities and /about exercised.
  EVIDENCE: 20 LiveView tests (role toggle, card select, review/escalate lanes with full probabilities and no bold recommendation, recorded 2025 latch without Noul, honest no-recording + explicit Noul skip, labeled oracle, underqualified sample, verdict framing + audit trail, storyline index with real verdict chips + lens filter + workbench deep-link, footer, /about formulas/provenance/pending evaluation). Live server: /, /storylines and /about 200 with content checks. Catalog boundary: 7 tests green; outer/state metric equality and PA/IP-sample equality enforced before any Judgments/Latch use.
- [x] G6: Prospective refusal, tamper detection, pending outcomes and scorer independently reviewed; no false accuracy claim.
  CHECK: mix test test/sabr_jev/{prospective,evaluation,capture_task,evaluate_task,record_task}_test.exs
  EXPECT: refusals for historical cohort, tamper, capture outside the cohort window, mixed cutoffs, missing outcomes pending
  EVIDENCE: leaf-4 gate G1/G2/G3 pass; docs/evaluation.md documents all refusals; `status: "prospective, accuracy pending"` in reports; no accuracy claim claimed. Cohort definition corrected (2026-09-22): the enrollable cohort is the newest pinned season (2025 → 2026, cutoff 2026-01-01) instead of `latest_frozen_season + 1`, which had asked for a card no pin could produce; `retrospective?/1` is now `year + 1 <= latest_frozen_season`; capture refuses a closed window as `:window_closed`; a prospective prediction is recorded by `mix sabr.record --prospective` (Noul without an oracle marker, `mode: prospective`, separate `priv/jev/recordings/prospective/`) and both capture and the scorer refuse any line whose mode is not prospective; the report's `cutoff` is the ledger's frozen cutoff. Real-catalog test asserts the closed window per card. Live check 2026-09-22: two real prospective recordings validated (batter judge 2025 Noul 0.48, pitcher Skene 2025 Noul 0.21), then capture refused them `:window_closed`. Prospective accuracy remains pending: no cohort outcome exists.
- [x] G7: Independent spec then quality reviews approve integrated build.
  EVIDENCE: leaf-3 and leaf-4 gates pass; root G4/G6 verified.
