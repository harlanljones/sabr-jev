# Gates: Pinned Lahman ETL and metric cards

OWNS: scripts/**, tests/**, data/**, priv/data/**, Makefile, docs/data.md

- [x] G1: Relevant automated tests pass.
  CHECK: python3 -m unittest discover -s tests -v
  EXPECT: OK
  EVIDENCE: Parent ran 23 tests with no skips, exit 0; real SQL metric/oracle checks and byte-identical offline rebuild passed. Parent independently verified source checksums, SQLite integrity (ok), and 12 unique cards.
- [x] G2: Independent spec compliance review passes.
  EVIDENCE: PASS deleg_89e6171e; missing FIP definition citation added to docs/data.md.
- [x] G3: Independent quality review passes.
  EVIDENCE: APPROVED deleg_a99611e2; reviewer independently ran all 23 tests without skips.
