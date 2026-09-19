# Sabr-Jev metrics discussion — batting + pitching

**Product bet:** season cards → Jev triage (regress | sustain | improve | other) + Noul on a specific binary + Score sample-noise risk.  
**Rule:** code owns every number on the card; Jev never computes rates.

---

## Batting: accuracy vs free-data honesty

| Metric | What it is | Source / compute burden | Accuracy for “true talent” | Sabr-Jev verdict |
|--------|------------|-------------------------|----------------------------|------------------|
| **BA / OBP / SLG / OPS** | Classic rates | Lahman trivial | Weak (BA), OPS better but equal-weights walks poorly | Good **inputs** on card; bad as sole triage target |
| **ISO, BB%, K%, BABIP** | Shape / luck signals | Lahman trivial | Strong for *process* story (BABIP spikes → regress narrative) | Excellent **features** for state JSON |
| **OPS+** | Park- & league-adjusted OPS (~100 = avg) | Approximable from Lahman + home park PF (Retrosheet/team runs or published PF tables) | Very good; ≈wRC+ in practice (near-perfect correlation) | **Best free-data “headline +” for v1** |
| **wOBA** | Linear-weights OBP-scale | Lahman events + **year-specific weights** (Tango/FG constants — public tables) | Better event weighting than OPS | Strong card field; weights must be **pinned by season** in repo |
| **wRC+** | Park-adjusted runs created from wOBA (~100 = avg) | wOBA + PF + league R/PA + pitcher-excluded league baseline | Gold-standard *rate* offense | **Worth computing if** we pin FG/Tango constants + a documented PF method — else don’t claim “wRC+” |
| **FanGraphs published wRC+** | Canonical leaderboard | Not a free bulk dump for redistribution | Highest “face validity” | **Out** as primary spine (paywall / ToS / scrape risk). Optional human-compare in private eval only |
| **WAR** | Positional + baserunning + fielding + replacement | Multi-system mess | Best *value* summary | **Out of v1** — too many free-data holes |

### Practical recommendation (offense)

1. **Card headline (v1):** `ops_plus` we compute + document (Lahman + pinned park factors).  
2. **Also on card (code):** `woba` (pinned seasonal weights), `ops`, `iso`, `bb_pct`, `k_pct`, `babip`, `pa`, YoY deltas, age.  
3. **Optional stretch:** our `wrc_plus_approx` — same formula family as FG, labeled **approx** until PFs match a cited method.  
4. **Jev Noul target (eval-friendly):** e.g. “OPS+ falls ≥10 next season” or “wOBA drops ≥.020” — pick one and freeze. Prefer **OPS+** for label simplicity if PF pipeline is ready; prefer **wOBA** if we want to avoid PF noise in the *label*.  
5. **Score sample-noise:** driven by PA + BABIP/HR-FB extremes (code features; Jev only *judges* the card).

**Accuracy tradeoff in one line:** wRC+ is slightly better theory; OPS+ is ~as good empirically and much easier to defend on Lahman-only builds. For a competition, **honest OPS+ + wOBA + luck shape** beats a shaky “wRC+” that doesn’t match FanGraphs.

---

## Pitching complement (same triage spine)

Parallel **pitcher-season cards** with the same Choice/Noul/Score pattern.

| Metric | Compute from free data? | Role on card |
|--------|-------------------------|--------------|
| **ERA, IP, G, GS, K, BB, HR, HBP** | Lahman easy | Raw spine |
| **K/9, BB/9, K-BB%, HR/9** | Lahman easy | Process |
| **FIP** | Lahman (HR, BB, HBP, K, IP) + seasonal FIP constant | **Headline “deserved” ERA proxy** |
| **ERA− / ERA+** | Needs park factors (same PF problem as OPS+) | Park-adjusted outcome |
| **xFIP** | Needs FB% → Statcast/batted-ball; not Lahman-pure | Optional Savant enrich |
| **SIERA** | More complex; skip v1 | Out |
| **WHIP, BABIP, LOB%** | Lahman (LOB% needs R/ER/H/BB/HBP/IP care) | Luck / regression tells |

### Pitching recommendation (v1)

1. **Headline:** `fip` + `era` + `k_minus_bb_pct` + `ip` + YoY deltas.  
2. **Park-adjusted stretch:** `era_plus` once PF pipeline exists (shared with offense).  
3. **Optional Savant enrich:** `avg_exit_velo`, `whiff_pct`, `xera`-like aggs — local CSVs only.  
4. **Jev Noul:** “FIP rises ≥0.50 next season” or “ERA− worsens ≥10” — freeze one.  
5. **Same gates:** Choice `{regress, sustain, improve, other}` · Score sample-noise (IP-based) · confidence latch.

**Why FIP not ERA as the *story* metric:** ERA is noisier (sequence, LOB, defense); FIP is the pitching twin of “process over results” and is fully Lahman-computable — mirrors using BABIP/ISO beside OPS+ on offense.

---

## Unified product shape

```
Lahman (+ Retrosheet PF / optional Savant)
        → batter_card.json  OR  pitcher_card.json
        → Jev batch:
             Choice outlook
             Noul  (metric-specific binary, frozen)
             Score sample_noise
        → AUTO / REVIEW / HUMAN
        → T+1 label from next Lahman season → Brier
```

One UI with a **Batter | Pitcher** toggle; shared latch + calibration chart; separate question YAML + baselines.

---

## What not to do

- Don’t ask Jev “what is this player’s wRC+.”  
- Don’t scrape FanGraphs leaderboards into the public repo.  
- Don’t use WAR as the Noul target in v1.  
- Don’t share Noul vs Choice confidence thresholds.

---

## Suggested freeze-ready defaults (when you freeze)

| Lane | Card headline | Noul label (T+1) | Baseline |
|------|---------------|------------------|----------|
| Batter | OPS+ (ours) + wOBA | OPS+ down ≥10 | Predict regress if BABIP high & PA mid |
| Pitcher | FIP + K-BB% | FIP up ≥0.50 | Predict regress if LOB% high / BABIP low |

