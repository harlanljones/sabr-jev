# PRD: Sabr-Jev — season cards × TypeSafe Jev latch

| | |
|---|---|
| Product | Sabr-Jev |
| Version | 0.1.1 |
| Status | **CONDITIONAL APPROVE.** Wedge and Lahman-first spine are real. Rewrite freezes code vs Jev, OPS+/wOBA honesty, and Noul latch rules. |
| Sibling | **Count Gate parked** (not lead). Not Skipper. |
| Repo | greenfield `harlanljones/sabr-jev` |
| Do not | Live FG scrape for primary metrics; chat gen; Jev invents numbers; undocumented OPS+ parity; Count Gate PA router as lead |

Audit 2026-09-18. Does not implement.

---

## 1. What is actually true

### Lahman-only headlines

| Metric | Feasible from Lahman counting stats? | Spec note |
|---|---|---|
| OPS, OBP, SLG, ISO, BABIP, BB%, K%, PA | **Yes** | Standard derived stats; stint-merge + NA coalesce documented (SF/IBB/HBP historically sparse). |
| **OPS+ (ours)** | **Yes, with recipe** | Use league OPS + **Teams.BPF** (3-year batting park factor). Label **OPS+ (Sabr-Jev)** on card + `/about`. Never claim Fangraphs/BBRef identity. |
| **wOBA** | **Yes counts + external weights** | Numerator/denom from Lahman; **year weights are not in Lahman**. Commit `data/woba_weights.csv` (Fangraphs Guts **constants export**, cited; **no runtime scrape**). Missing year → omit wOBA or mark `unavailable`. |
| **FIP + cFIP** | **Yes** | `((13*HR)+(3*(BB+HBP))-(2*SO))/IP + cFIP` with `cFIP` from league ERA identity (Lahman aggregates). Cite FG FIP definition. IP from `IPouts/3`. |
| GB% | **No in classic Lahman** | Omit from v0 pitcher shape (as draft said). |
| scraped wRC+/WAR | **Out** | Optional `wrc_plus_approx` only if labeled approx + formula cited — not headline. |

**Verdict:** Lahman-primary headlines work. wOBA is not “Lahman-only” in the strict sense — it needs a **frozen weights file**. That is OK if D0 names the file and forbids live scrape.

### Noul confidence floor vs latch

TypeSafe: Noul has **no API confidence**; client derives `max(noul, 1-noul)` with **floor 0.5**. `Answer.gate/2` needs `review:` **> 0.5** for Noul; **`:escalate` is effectively unreachable** on Noul alone.

**Rewrite rule:**

| Answer type | Latch |
|---|---|
| Choice / Score | Full `:act` / `:review` / `:escalate` via peakedness confidence |
| Noul | **`:act` / `:review` only** (review threshold > 0.5). Do **not** pretend escalate works on Noul conf. UI may still escalate the **card** if any Choice/Score escalates. |

Primary product latch for “bold recommend” = **Choice `season_read` (+ role profile)** confidence. Next-season Noul is a **calibration / secondary pane**, not the sole escalate driver.

### Retrosheet

Optional. Notice **mandatory only if Retrosheet data appears** in card, ETL, or redistributed tables. v0 may ship **Lahman-only** → D4 = N/A, footer still says Lahman cite + “no FG scrape.”

Canonical notice when used:  
*The information used here was obtained free of charge from and is copyrighted by Retrosheet. Interested parties may contact Retrosheet at 20 Sunset Rd., Newark, DE 19711.*

### Wedge vs siblings

| Product | Relation |
|---|---|
| Count Gate | Parked sibling (PA/Statcast router). Different demo. |
| Skipper | Dugout sim — out of scope. |
| FG / BBRef boards | No System One latch. |
| Chat scout | Untyped prose — falsifier. |

**Wedge holds:** confidence-gated season-card workbench; math in code; Jev typed only; product = latch.

---

## 2. Verdict

| Ask | Result |
|---|---|
| Lahman-only headlines? | **Conditional yes** — OPS+ (ours) + FIP yes; wOBA needs committed weights CSV |
| wOBA without live scrape? | **Yes** — static cited CSV |
| OPS+ labeling? | **Must** say Sabr-Jev recipe |
| Noul floor vs latch? | **Tighten** — Noul act/review only; Choice/Score own escalate |
| Retrosheet? | Optional + notice-if-used |
| Wedge vs Count Gate/Skipper? | **Clear** |

**Overall: CONDITIONAL APPROVE.**

---

## 3. Frozen bet

**Sabr-Jev** = Batter|Pitcher season cards from free public stats → JSON state (precomputed) → Jev Choice/Score/Noul → **confidence latch**. No chat gen. No FG scrape clone. Count Gate stays parked.

---

## 4. Product thin slice

1. Toggle Batter | Pitcher.  
2. Pick `playerID` + `yearID` (stint-merge: PA/IP-weighted or sum-then-rate — **pick one in D1 and freeze**).  
3. Card: headlines + shape (code).  
4. Jev pack on state JSON only.  
5. Latch: Choice/Score → act/review/escalate; Noul → act/review only; review lane shows full probs, no single bold recommend.  
6. Footer: Lahman cite; Retrosheet notice **iff used**; “no Fangraphs scrape in v1.”

### Metrics (frozen)

| Role | Headline | Shape | Next-season Noul (if T+1 row) |
|---|---|---|---|
| Batter | **OPS+ (Sabr-Jev)** + **wOBA** | ISO, BB%, K%, BABIP, PA | `ops_plus_drop_ge_10_next` |
| Pitcher | **FIP** + **ERA** + **K-BB%** | IP, HR/9, BB/9, K/9 | `fip_rise_ge_0_50_next` |

### Jev pack (rewritten)

**Shared**

- Choice `season_read`: `breakout | stable | regression_risk | small_sample | other`  
- Score `confidence_in_signal`: weak → moderate → strong — criteria about **interpretation given the numbers already on the card**, not “recompute whether PA≥N”

**Code (not Jev)**

- Min sample: if PA < N / IP < M → **force** UI into review or auto-select path that surfaces `small_sample` without asking Jev a deterministic Noul. **Kill `meets_min_sample` Noul** (skill-wash).

**Batter / Pitcher**

- Choice `profile` (+ `other`) as in draft  
- Next-season Noul only when T+1 exists in ETL; never put T+1 rates on the T card used for judgment of T (label join is eval-only or a clearly marked “oracle pane”)

---

## 5. Data / formula gates

| Gate | Requirement |
|---|---|
| **D0** | `/about`: OPS+ (Sabr-Jev) formula + BPF use; wOBA formula + `woba_weights.csv` provenance; FIP/cFIP; SF/IBB/HBP coalesce |
| **D1** | Lahman load; stint-merge rule frozen; min PA/IP filters in **code** |
| **D2** | Frozen question IDs + criteria text in repo |
| **D3** | Latch τ provisional **or** mini-labeled (N≥30); UI labels provisional if untuned |
| **D3b (add)** | If shipping next-season Noul: holdout years + **Brier** on that Noul vs realized T+1 (even small N) — or mark “demo-only, uncalibrated” |
| **D4** | Retrosheet notice iff Retrosheet used |

**Offline CI:** recorded Jev fixtures (no key required for latch UI tests).

---

## 6. Stack pin

| Piece | Pin |
|---|---|
| App | Elixir + Phoenix LiveView |
| Jev | `typesafe_api` / `jev-latest`; `TYPESAFE_API_KEY` |
| ETL | Makefile → SQLite/Parquet (Python or Elixir) |
| Anti-default | No CRA + chat scout; no live FG scrape |

---

## 7. Acceptance

1. Cards real from Lahman + documented formulas.  
2. ≥1 Choice + ≥1 Score + (≥1 Noul **or** explicit skip when no T+1).  
3. Latch real — product feels broken without it.  
4. No invent — state precomputed only.  
5. Lineage real.  
6. Not Count Gate / not Skipper.

---

## 8. Falsifiers

- Works without latch  
- Live FG scrape primary  
- Jev computes batting line from prose  
- Chat writeup  
- Count Gate as lead  
- Undocumented OPS+ parity claim  
- Deterministic sample check implemented as Noul  
- Noul-only escalate path claimed

---

## 9. Risks (updated)

| Risk | Mitigation |
|---|---|
| OPS+ ≠ FG | Label Sabr-Jev; publish formula |
| wOBA weights | Committed CSV; cite; no scrape |
| Noul conf floor | Separate latch rules; Choice/Score own escalate |
| Deterministic Noul | Code min-sample gate |
| Leakage T+1 | Eval join ≠ judgment state |
| Skipper / Count Gate collision | Explicit OOS |

---

## 10. One-line Spec verdict

**CONDITIONAL APPROVE:** season-card × Jev latch is shippable on Lahman + static wOBA weights; kill sample Noul; split Noul vs Choice/Score latch; label OPS+ (Sabr-Jev); Count Gate stays parked.
