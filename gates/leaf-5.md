# Gates: Integrated workbench

OWNS: lib/sabr_jev/catalog.ex, lib/sabr_jev_web/**, assets/**, priv/static/**, test/sabr_jev_web/**, README.md

- [x] G0: Catalog establishes the trusted card boundary before judgment or routing.
  CHECK: mix test test/sabr_jev/catalog_test.exs
  EXPECT: exact outer keys and ID/role/year; outer/shared metric equality; batter PA or pitcher IP equals sample.value; mutations rejected before Judgments/Latch
  EVIDENCE: 7 tests, 0 failures. `Catalog.load_recording/1` re-validates the card before any recording use, so outer/state drift cannot be laundered past the boundary.
- [x] G1: Relevant automated tests pass.
  CHECK: mix test
  EXPECT: 0 failures
  EVIDENCE: env -u TYPESAFE_API_KEY mix test: 97 tests, 0 failures (30 real recordings: 25 with oracle Noul + 4 qualified 2025 Choice/Score-only + Strider 2023 without oracle). Python ETL suite still 23/23 OK. mix format --check-formatted and mix compile --warnings-as-errors exit 0. Live HTTP exercise: / and /about return 200 with 11/11 content checks.
- [x] G2: Independent spec compliance review passes.
  EVIDENCE: Cycle 1 SPEC PASS (G0 boundary, full UI, latch rules, no invention, falsifiers, no overclaims; one non-blocking latent note on Noul-skip placement).
- [x] G3: Independent quality review passes.
  EVIDENCE: Cycle 1 QUALITY PASS (format/compile clean, fail-closed paths, no cycles, no XSS, mirroring documented). Six non-blocking advisories; four applied (test smell, pinned route, get/2 fallback, mirror comment), two accepted (untested corrupt-catalog edges fail closed by inspection). Re-verified: 87 tests, 0 failures; format and warnings-as-errors green.
