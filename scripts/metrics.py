"""Pure count-first metrics. Rates are fractions, never rounded for storage."""
import math
from collections import defaultdict

BATTING = ("AB", "H", "X2B", "X3B", "HR", "BB", "SO", "HBP", "SF", "SH", "IBB")
OPTIONAL = {"HBP", "SF", "IBB"}


def ratio(numerator, denominator):
    if numerator is None or denominator is None or denominator <= 0:
        return None
    return numerator / denominator


def calculate(formula):
    """A missing core input propagates only to metrics depending on it."""
    try:
        return formula()
    except TypeError:
        return None


def count(value, key, warnings):
    if value is None or value in ("", "NA"):
        warnings.add(f"{key} missing: " + ("assumed zero" if key in OPTIONAL else "unavailable"))
        return 0 if key in OPTIONAL else None
    number = float(value)
    if not math.isfinite(number) or number < 0 or not number.is_integer():
        raise ValueError(f"Invalid {key} count: {value!r}")
    return int(number)


def aggregate(rows, keys):
    totals = dict.fromkeys(keys, 0)
    warnings = set()
    for row in rows:
        c = {key: count(row.get(key), key, warnings) for key in keys}
        invalid = []
        if "AB" in c:
            # Known partial counts can already disprove consistency; unknowns
            # are not filled in the returned totals or any derived metric.
            invalid = [calculate(lambda: sum(c[k] for k in ("H", "SO") if c[k] is not None) > c["AB"]),
                       calculate(lambda: sum(c[k] for k in ("X2B", "X3B", "HR") if c[k] is not None) > c["H"]),
                       calculate(lambda: c["IBB"] > c["BB"])]
        elif "BFP" in c:
            invalid = [calculate(lambda: sum(c[k] for k in ("SO", "BB", "HBP", "HR") if c[k] is not None) > c["BFP"])]
            if row.get("H") not in (None, "", "NA"):
                hits = count(row["H"], "H", warnings)
                invalid.append(calculate(lambda: c["HR"] > hits))
        if any(invalid):
            raise ValueError(f"Inconsistent counts for {row.get('playerID', 'league')}")
        for key in keys:
            totals[key] = calculate(lambda: totals[key]+c[key])
    return totals, warnings


def batter_metrics(rows, weights):
    counts, warnings = aggregate(rows, BATTING)
    ab, h, doubles, triples, hr, bb, so, hbp, sf, sh, ibb = counts.values()
    singles = calculate(lambda: h-doubles-triples-hr)
    tb = calculate(lambda: singles+2*doubles+3*triples+4*hr)
    pa = calculate(lambda: ab+bb+hbp+sf+sh)
    obp = calculate(lambda: ratio(h+bb+hbp, ab+bb+hbp+sf))
    slg = ratio(tb, ab)
    result = dict(pa=pa, obp=obp, slg=slg, ops=calculate(lambda: obp+slg),
                  iso=calculate(lambda: ratio(tb-h, ab)),
                  babip=calculate(lambda: ratio(h-hr, ab-so-hr+sf)),
                  bb_pct=ratio(bb, pa), k_pct=ratio(so, pa))
    result["woba"] = None
    if weights is None:
        warnings.add("wOBA weights unavailable")
    else:
        result["woba"] = calculate(lambda: ratio(
            weights["wBB"]*(bb-ibb)+weights["wHBP"]*hbp+weights["w1B"]*singles+
            weights["w2B"]*doubles+weights["w3B"]*triples+weights["wHR"]*hr,
            ab+bb-ibb+hbp+sf))
    return result, sorted(warnings)


PITCHING = ("IPouts", "ER", "HR", "BB", "HBP", "SO", "BFP")


def pitching_base(rows):
    c, warnings = aggregate(rows, PITCHING)
    outs, er, hr, bb, hbp, so, bfp = c.values()
    ip = calculate(lambda: outs/3)
    component = calculate(lambda: ratio(13*hr+3*(bb+hbp)-2*so, ip))
    metrics = dict(ip=ip, era=calculate(lambda: ratio(27*er, outs)),
                   k_bb_pct=calculate(lambda: ratio(so-bb, bfp)),
                   hr_per_9=calculate(lambda: ratio(27*hr, outs)),
                   bb_per_9=calculate(lambda: ratio(27*bb, outs)),
                   k_per_9=calculate(lambda: ratio(27*so, outs)))
    return metrics, component, warnings


def league_context(batting_rows, pitching_rows):
    """All AL/NL players, including samples below the card threshold."""
    context = defaultdict(lambda: {"obp": None, "slg": None, "cfip": None, "warnings": []})
    for kind, rows in (("batter", batting_rows), ("pitcher", pitching_rows)):
        groups = defaultdict(list)
        for row in rows:
            if row["lgID"] in ("AL", "NL"):
                groups[(int(row["yearID"]), row["lgID"])].append(row)
        for key, group in groups.items():
            if kind == "batter":
                metrics, warnings = batter_metrics(group, None)
                context[key].update(obp=metrics["obp"], slg=metrics["slg"])
                warnings = [w for w in warnings if w != "wOBA weights unavailable"]
            else:
                metrics, component, warnings = pitching_base(group)
                context[key]["cfip"] = calculate(lambda: metrics["era"]-component)
            context[key]["warnings"].extend(f"League {key[1]} {w}" for w in warnings)
    return dict(context)


def weighted(values, weights):
    if any(value is None or weight is None for value, weight in zip(values, weights)):
        return None
    return ratio(sum(value*weight for value, weight in zip(values, weights)), sum(weights))


def context_values(rows, contexts, metric, warnings):
    result = []
    for row in rows:
        context = contexts.get((int(row["yearID"]), row["lgID"]), {})
        warnings.update(context.get("warnings", []))
        value = context.get(metric)
        if value is None:
            warnings.add(f"League {row['lgID']} {metric} unavailable")
        result.append(value)
    return result


def contextual_batter(rows, weights, contexts, teams):
    result, messages = batter_metrics(rows, weights)
    warnings = set(messages)
    pa_weights = [batter_metrics([row], weights)[0]["pa"] for row in rows]
    for metric in ("obp", "slg"):
        result[f"league_{metric}"] = weighted(context_values(rows, contexts, metric, warnings), pa_weights)
    parks = []
    for row in rows:
        raw = teams.get((int(row["yearID"]), row["teamID"]))
        park = float(raw) if raw not in (None, "", "NA") else None
        if park is not None and (not math.isfinite(park) or park <= 0):
            raise ValueError(f"Invalid Teams.BPF: {raw!r}")
        if park is None:
            warnings.add(f"Teams.BPF unavailable for {row['teamID']}")
        parks.append(park)
    bpf = weighted(parks, pa_weights)
    result["park_adjustment"] = calculate(lambda: (1+bpf/100)/2)
    result["ops_plus"] = calculate(lambda: 100*(
        ratio(result["obp"], result["league_obp"]*result["park_adjustment"])+
        ratio(result["slg"], result["league_slg"]*result["park_adjustment"])-1))
    return result, sorted(warnings)


def pitcher_metrics(rows, contexts):
    result, component, warnings = pitching_base(rows)
    outs = [count(row.get("IPouts"), "IPouts", warnings) for row in rows]
    result["league_cfip"] = weighted(context_values(rows, contexts, "cfip", warnings), outs)
    result["fip"] = calculate(lambda: component+result["league_cfip"])
    return result, sorted(warnings)
