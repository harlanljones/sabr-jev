# Gates: Typed Jev and confidence latch

OWNS: lib/sabr_jev/**, lib/mix/tasks/sabr.record.ex, test/sabr_jev/**, priv/jev/**

- [x] G1: Relevant automated tests pass.
  CHECK: mix test test/sabr_jev
  EXPECT: 0 failures
  EVIDENCE: Parent ran 26 tests, format check and warnings-as-errors; six immutable real recordings validate and route against pinned cards.
- [x] G2: Spec scope accepted with explicit deferred catalog boundary.
  EVIDENCE: Reviews deleg_b013ae6a, deleg_0c3e060d and deleg_208335cd closed typed/state/oracle/response/latch gaps. After the third cycle, Harlan explicitly chose "Defer these checks to catalog loading" for exact outer-card and PA/IP consistency. Those checks are now hard gates in task 5.
- [x] G3: Independent quality review passes.
  EVIDENCE: Parent ran `env -u TYPESAFE_API_KEY mix test` (72 tests, 0 failures), `mix format --check-formatted` and `mix compile --warnings-as-errors` exit 0. Six immutable real recordings validate and route against pinned cards. Code reviewed: freeze-closed question definitions, state_hash/questions_hash domain separation, exact serialized/raw answer validation, confidence latch with Noul-only review (never escalate on Noul alone), no deterministic sample-check Noul.
