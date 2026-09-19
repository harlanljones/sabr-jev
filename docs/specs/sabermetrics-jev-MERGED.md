# Sabermetrics × Jev — Merged Design (freeze candidate)

**Date:** 2026-09-18 PT  
**Inputs:** Project Lab brainstorm · Spec Auditor outline (`OUTLINE-sabermetrics-jev.md`) · X Research Bot ClutchGate draft  
**Status:** Awaiting Harlan freeze

---

## Shared spine (both agents agree — non-negotiable)

| Rule | Owner |
|------|--------|
| Free public data only: **Lahman** + **Retrosheet** (+ optional **Savant/Statcast** aggs) | Pipeline |
| **Retrosheet attribution** on UI + README (mandatory wording) | Ship gate |
| Math / rates / counts / dates / labels / Brier → **code** | Code |
| Jev = **Choice / Score / Noul** only; **no generation** | Jev |
| Atomic questions; small JSON state; no wOBA/FIP computed in prompts | Boundary |
| Confidence → **AUTO / REVIEW / HUMAN** (separate thresholds per primitive type) | Gate |
| Eval: frozen holdout + **Brier** (+ reliability buckets); beat code-only baseline | Spec gate |
| Non-goals: betting/DFS, fangraphs clone, proprietary feeds, chatty scout prose | Scope |

---

## Two viable primaries (pick one)

### A. **Count Gate** — Project Lab top pick *(recommended for competition wow)*

**Product:** Scrub a Statcast PA. Code builds features (count, platoon, pitch-mix %, whiff/chase/xBA buckets). Jev returns:
- `Choice plan`: challenge | expand_zone | soft_contact | waste | other
- `Noul steal_threat_count`
- `Score aggressiveness`

**The feature is the confidence latch** (auto-surface plan vs show full distribution for review) — falsify by removing gating.

**Demo (3 canned PAs):** high-conf challenge · low-conf expand/soft split · steal-threat Noul flips plan.

**Data emphasis:** Savant/Statcast week slice via `pybaseball` (+ Lahman for context). Keep raw Statcast out of public repo if ToS requires; document fetch.

**Applies Spec Auditor gates:** Retrosheet notice if used; code/Jev boundary; Brier on Noul (e.g. steal threat or post-hoc “did plan match outcome class”); baseline = fixed spreadsheet thresholds; freeze question text.

**Pros:** Sharpest Jev story · real-time feel · clearest “not a spreadsheet”  
**Cons:** Heavier UX; Statcast ToS care; weaker classic sabermetrics narrative than season-card triage

---

### B. **Sabr-Jev Sustainment Triage** — Spec Auditor thin-slice *(recommended for sabermetrics purity + eval rigor)*

**Product:** Code builds compact **player/pitcher-season JSON cards** (Lahman + Retrosheet). Jev returns:
- `Choice outlook`: regress | sustain | improve | other
- `Noul` e.g. OPS+ drop ≥10 next season
- `Score` sample-noise risk

**Demo:** attribution → 2 cards → Jev → gate → T+1 label reveal → holdout Brier chart → show a low-conf miss.

**Data emphasis:** Lahman primary spine; Retrosheet for splits; Statcast optional aggs only.

**Pros:** Cleanest free-data license story · honest T+1 labels · Spec Auditor PRD-ready  
**Cons:** Less “wow” UX than PA scrubber; easier for judges to say “that’s just regression to the mean”

---

### Parked (same spine)
- **Claim Desk** (Project Lab): hot-take auditor — fastest poster demo  
- **Leverage Latch / ClutchGate**: bullpen role router — skipper-adjacent  
- Share architecture, gates, eval pattern with whichever primary wins

---

## Recommended freeze

**Competition demo track:** freeze **Count Gate (A)** as the build target.  
**Borrow Spec Auditor’s entire compliance/eval skeleton** (licenses, boundary rules, Brier, baseline, question-text freeze, gate separation).

If judges are sabermetrics academics first: freeze **B** instead.

---

## Build order (once frozen)

1. Spec Auditor full PRD on chosen primary (acceptance tests).  
2. API path: TypeSafe waitlist **or** Vercel AI Gateway `typesafe-ai/jev`.  
3. Day 1: ingest + feature/card builder + Retrosheet notice.  
4. Day 2: Jev client + gate + 3–10 canned demos.  
5. Day 3: labels/eval chart + UI polish + `/about` licenses.

---

## Open decision for Harlan

Freeze **A Count Gate**, **B Sustainment Triage**, or **Claim Desk** (fast poster)?
