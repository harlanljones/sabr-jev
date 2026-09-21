# Gates: Prospective ledger and evaluation

OWNS: lib/sabr_jev/**, lib/mix/tasks/**, test/sabr_jev/**, docs/evaluation.md

- [x] G1: Relevant automated tests pass.
  CHECK: mix test test/sabr_jev
  EXPECT: 0 failures
  EVIDENCE: Parent ran `env -u TYPESAFE_API_KEY mix test`: 71 tests, 0 failures; `mix format --check-formatted` and `mix compile --warnings-as-errors` exit 0; Python ETL suite still 23/23 OK.
- [x] G2: Independent spec compliance review passes.
  EVIDENCE: Cycle 1 FAIL with 10 gaps (overwrite instead of append, non-threaded ledger fork, substring duplicate check, no verify on write/score paths, invented 0.5/ops_plus defaults in evaluate, no target==noul_id check, unfrozen baseline, 6-ID-only retrospective list, injection-only capture time, timestamp caveat only in docs). Cycle 2 FAIL, narrow: production record source unimplemented, false "detects overwrite" claim, MatchError instead of refusals; plus residual items (library verify contract, probability range, capture-time invariant at score time, cohort-window derivation, report markers, central noul-id mapping). All closed; Cycle 2 re-review PASS.
- [x] G3: Independent quality review passes.
  EVIDENCE: Cycle 3 CHANGES REQUESTED with B1 (captured_at nil cutoff bypass), B2 (verify raises KeyError off-spec), B3 (undocumented dual probability keys), S1-S6, N1-N4. All fixed: cutoff fail-closed and tested, Map.pop-based hash check, single documented record shape, noul-id/role mapping centralized in SabrJev.Questions (capture task now calls Questions.noul_id/1 instead of hardcoding), roles opt removed, cutoff uniformity moved to Evaluation.score with a test, outcomes shape guard, duplicate test helper removed, ?-suffix renames, empty cohort writes no file. Cycle 3 re-review PASS; 72 tests, 0 failures; format and warnings-as-errors green.
