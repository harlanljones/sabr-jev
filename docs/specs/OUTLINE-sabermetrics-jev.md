# Spec outline: Count Gate (+ runners-up) — TypeSafe Jev sabermetrics

**Primary product:** Count Gate  
**Runners-up (same architecture):** Claim Desk, Leverage Latch  
**Repo (planned):** greenfield `harlanljones/count-gate` (or umbrella later)  
**Constraint spine:** Jev = one **text/JSON state** + typed **Noul / Choice / Score** only; **no generation**; arithmetic / dates / counts / Statcast aggs in **code**; confidence → **auto / review / human** latch.

For X Research Bot + Project Lab → Harlan scope freeze → Spec Auditor PRD.

---

## 0. Scope freeze recommendation

**Ship Count Gate as v1.** Park Claim Desk / Leverage Latch as v1.1 skins on the same card builder + Jev client + gate + eval harness — do not build three products in parallel.

---

## 1. Count Gate — goals

**One-liner:** Scrub a plate appearance (or in-PA count state) built from **Statcast (+ Retrosheet/Lahman join keys)**; **code** fills the card; **Jev** answers plan / steal threat / aggressiveness; **product** is a **confidence latch** (auto-act vs review vs human) — not a chatty coach.

1. Ingest bounded Baseball Savant Statcast CSVs (PA/pitch rows) + optional Retrosheet/Lahman for identity/context.
2. Code builds a compact **count-state JSON** (outs, bases, balls/strikes, batter/pitcher handedness, recent pitch mix summaries, run expectancy inputs if available).
3. Jev batch:
   - **Choice `plan`:** e.g. `{challenge, waste, expand, pitch_out, intentional, other}` (always include `other`).
   - **Noul `steal_threat`:** P(true) that a steal attempt is a live threat this pitch / this count.
   - **Score `aggressiveness`:** ordered levels e.g. `passive → balanced → attack → max_attack`.
4. **Confidence latch:** map Choice/Score confidence (+ Noul-derived conf, **separate thresholds**) → `auto` | `review` | `human`.
5. Eval against frozen labeled holds (see §6); demo shows latch behavior, not WAR essays.

---

## 2. Non-goals (Count Gate)

- Free-text pitch calling or generated scouting reports (Jev has **no generation**).
- Live in-game betting / DFS tips.
- Full Statcast warehouse mirror in the public repo.
- Asking Jev to compute EV, wOBA, RE24, count frequencies — those are **code fields on the card**.
- Claiming Jev confidence = calibrated accuracy (peakedness ≠ Brier; we measure calibration ourselves).
- Three-product parallel build (Claim Desk / Leverage Latch stay outline-only until Count Gate gates pass).

---

## 3. Data sources + licenses

| Source | Count Gate use | Notes |
|---|---|---|
| **Baseball Savant Statcast CSV** | Primary PA/pitch features | Public search CSV; **MLBAM rights reserved**. Prefer **bounded, provenance-logged downloads** in `data/raw/` (or local-only). Do not mass-scrape in CI. If redistribution of raw CSVs is unclear, keep raw private; ship **aggregates + card schema** only. |
| **Retrosheet** | Optional game/event join, park, lineup context | Free use incl. commercial; **mandatory prominent notice** on README, demo UI, and any redistributed Retrosheet-derived tables: *“The information used here was obtained free of charge from and is copyrighted by Retrosheet. Interested parties may contact Retrosheet at 20 Sunset Rd., Newark, DE 19711.”* (Also retain `notice.txt` / www.retrosheet.org wording if using older packs.) No accuracy warranty. |
| **Lahman / Chadwick** | Player/team identity, season priors on card | Pin repo tag + license file in `/about`. |

**Hard out:** inventing pitch sequences; paywalled feeds; omitting Retrosheet notice when Retrosheet facts appear.

---

## 4. Architecture — code vs Jev (shared by all three)

```
Statcast(/Retrosheet/Lahman) CSV
        → feature ETL (code)
        → state card JSON (+ optional deterministic text restatement)
        → TypeSafe Jev (Noul | Choice | Score)
        → confidence latch (auto | review | human)
        → log + eval labels
```

| Layer | Owns |
|---|---|
| **Code** | Joins; count/base/out encoding; pitch-mix tallies; RE/leverage inputs; chronology; labels; Brier/buckets; latch thresholds |
| **Jev** | Typed judgments only on the frozen card |
| **Latch** | `auto` = high conf + not `other`; `review` = mid; `human` = low conf or Choice=`other` or schema flags (e.g. missing EV) |

**Boundary rules (frozen):**

1. No arithmetic in Jev `instructions` (“add these velocities…”) — pass numbers as fields.
2. Stable card schema versioned in repo; Jev question defs versioned beside it.
3. Noul confidence (often `max(p,1-p)`, floor 0.5 in TypeSafe clients) **must not share thresholds** with Choice/Score confidence.
4. One state → one Jev call (batched questions); log model id + question hash.

---

## 5. Count Gate card schema (sketch)

JSON state examples (code-filled):

- Game: `game_pk`, `at_bat_number`, `pitch_number`, `inning`, `half`
- Count/base: `balls`, `strikes`, `outs`, `on_1b`, `on_2b`, `on_3b`
- Matchup: `stand`, `p_throws`, `batter_id`, `pitcher_id`
- Context aggs (precomputed): `pitcher_usage_pct_by_type`, `batter_whiff_pct_vs_type`, `prior_pitches_in_pa[]` summaries (counts/avgs, not raw dump)
- Optional: `delta_run_exp`, `leverage_index` if sourced in code
- Provenance: `sources`, `schema_version`, `built_at`

---

## 6. Eval plan (Count Gate)

| Piece | Spec |
|---|---|
| **Unit** | Pitch or PA-decision moment (pick one and freeze — recommend **before each pitch** with known count/bases) |
| **Labels** | From actual next events in Statcast/Retrosheet: e.g. steal attempt within PA; swing decision; pitch type bucket mapped to `plan` taxonomy (imperfect — document mapping); or expert-lite frozen CSV for v0 subset |
| **Noul `steal_threat`** | Binary: steal attempt occurs before next pitch outcome / before PA ends (define precisely) → **Brier** on `noul` |
| **Choice `plan`** | Map observed pitch call to taxonomy where possible; else `other`; report accuracy + log-loss; expect high `other` rate honestly |
| **Score `aggressiveness`** | Ordinal label from code heuristic (e.g. challenge% in 0-2 vs waste% in 3-0) as **baseline**; Jev Score vs that ordinal — MAE + bucket reliability |
| **Holdout** | Frozen date range / season chunk never used to edit criteria |
| **Latch utility** | Auto-band coverage × error rate; review burden |
| **Baseline** | Code-only rules (e.g. steal_threat = runner_on_1st & strikes≥1 & outs<2) — Jev must beat or match with better calibration in auto band |
| **Falsifier** | If Choice collapses to one option or never uses `other` → criteria fail |

**Jaggedness note:** Pitch “plan” labels are the weakest link (intent ≠ observed pitch). Spec should treat **steal_threat Noul + latch** as the **primary calibrated claim**; Choice/Score as product UX with honest label caveats.

---

## 7. Demo script (Count Gate)

1. Show Savant provenance + Retrosheet notice (if used).  
2. Scrub one PA: count advances; card JSON updates in code.  
3. Fire Jev → show `plan` probs, `steal_threat` p, `aggressiveness` score + confidences.  
4. Latch lights **auto** vs **review** vs **human**.  
5. Reveal what actually happened next pitch / steal.  
6. Flash holdout Brier for steal_threat + auto-band error rate.  
7. Show a forced **human** (low conf or `other`).

---

## 8. Runners-up — same boundary, different cards/questions

### Claim Desk

- **State:** dispute/claim packet JSON (box score line + Retrosheet event + optional news blurb **as pasted text already in state**, not scraped live by Jev).
- **Jev:** Choice `claim_type`; Noul `supports_claim`; Score `severity`.
- **Latch:** auto-file vs review vs human.
- **Eval:** frozen labeled claims; Brier on Noul; same harness.
- **Data:** Lahman/Retrosheet primary; Statcast optional.

### Leverage Latch (né closer-to-ClutchGate)

- **State:** late-inning leverage card (LI/RE24 from code, score, inning, pitcher fatigue proxies).
- **Jev:** Choice `bullpen_action` (stay/hook/matchup/`other`); Noul `high_leverage_now`; Score `urgency`.
- **Latch:** auto suggestion vs review vs human.
- **Eval:** next pitching change / run event labels; Brier; same harness.
- **Data:** Retrosheet + Lahman; Statcast optional.

**Shared kit:** card builder interface, Jev client, latch, eval (Brier + buckets), attribution footer. Only schema + question YAML change.

---

## 9. Risks (Count Gate–specific)

| Risk | Mitigation |
|---|---|
| Statcast ToS / raw CSV in git | Bounded local raw; public = code + cards + metrics |
| Plan labels ≠ intent | Primary metric = steal_threat; document Choice mapping limits |
| Noul/Choice conf mixup | Separate latch thresholds |
| Overfit criteria to demo PA | Freeze questions before holdout score |
| Skill-wash (pretty scrubber, dumb latch) | Baseline beat required on steal_threat Brier in auto band |
| Retrosheet notice missed | Checklist gate |

---

## 10. Spec Auditor gates (when PRD lands)

1. Count Gate primary; runners-up deferred.  
2. Code/Jev boundary explicit; no math in Jev.  
3. Savant provenance + Retrosheet notice (if used).  
4. Latch bands defined; Noul vs Choice/Score thresholds separated.  
5. Primary eval = steal_threat Brier + latch utility; Choice caveats written.  
6. Baseline comparison required.  
7. No UI polish before D1 card schema + D2 Jev question freeze + D3 holdout path.

---

## 11. One-liner for Harlan freeze

**Count Gate:** Statcast PA scrubber → code-built count cards → Jev Choice(plan) / Noul(steal_threat) / Score(aggressiveness) → confidence latch. Claim Desk & Leverage Latch reuse the same kit later.
