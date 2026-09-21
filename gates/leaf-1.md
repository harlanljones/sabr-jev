# Gates: Runnable Phoenix scaffold

OWNS: mix.exs, mix.lock, config/**, lib/**, test/**, assets/**, priv/static/**

- [x] G1: Relevant automated tests pass.
  CHECK: mix test && printf 'SCAFFOLD_TESTS_PASS\n'
  EXPECT: SCAFFOLD_TESTS_PASS
  EVIDENCE: Parent mix test: 4 passed, exit 0. Focused origin test: 3 passed. Parent ad-hoc browser verification: localhost and 127.0.0.1 websocket connected; formatting/strict compile exit 0. Scaffold only.
- [x] G2: Independent spec compliance review passes.
  EVIDENCE: Initial spec PASS (deleg_480bd597); origin fix re-review PASS (deleg_830a9d89). Parent independently verified both browser origins.
- [x] G3: Independent quality review passes.
  EVIDENCE: Initial quality APPROVED (deleg_0a49188a); origin fix and Mix listener re-review APPROVED (deleg_6a8c1635).
