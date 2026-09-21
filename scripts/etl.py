"""Pinned, stdlib-only Lahman -> SQLite + small deterministic season catalog."""
import argparse
from collections import defaultdict
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import tempfile
import urllib.request

from scripts.metrics import contextual_batter, league_context, pitcher_metrics

ROOT = Path(__file__).resolve().parents[1]
FORMULA_VERSION = "sabr-jev-v1"
STATE_METRICS = {
    "batter": ("pa", "obp", "slg", "ops", "iso", "babip", "bb_pct", "k_pct", "woba", "ops_plus", "league_obp", "league_slg", "park_adjustment"),
    "pitcher": ("ip", "era", "fip", "k_bb_pct", "hr_per_9", "bb_per_9", "k_per_9", "league_cfip"),
}


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)+"\n").encode("utf-8")


def verify_bytes(data, spec):
    actual = hashlib.sha256(data).hexdigest()
    if actual != spec["sha256"]:
        raise ValueError(f"SHA-256 mismatch for {spec['url']}: expected {spec['sha256']}, got {actual}")


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_input(spec, path, offline=False):
    """Never silently replace a corrupt cache or leave unverified download bytes."""
    path = Path(path)
    if path.exists():
        verify_bytes(path.read_bytes(), spec)
        return
    if offline:
        raise FileNotFoundError(f"Verified input absent: {path}; run make fetch first")
    if not spec["url"].startswith("https://"):
        raise ValueError("Input URLs must use HTTPS")
    with urllib.request.urlopen(spec["url"], timeout=90) as response:
        data = response.read()
    verify_bytes(data, spec)
    atomic_write(path, data)


def read_csv(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def prepare_inputs(manifest, raw_dir, weights_path, offline):
    tables = {}
    for name, spec in sorted(manifest["sources"].items()):
        path = raw_dir/f"{name}.csv"
        ensure_input(spec, path, offline)
        tables[name] = read_csv(path)
        if len(tables[name]) != spec["rows"]:
            raise ValueError(f"Row count mismatch: {name}")
    ensure_input(manifest["weights"], weights_path, offline)
    weight_rows = read_csv(weights_path)
    if len(weight_rows) != manifest["weights"]["rows"]:
        raise ValueError("Row count mismatch: weights")
    weights = {}
    for row in weight_rows:
        year = int(row["Season"])
        if year in weights:
            raise ValueError(f"Duplicate weights year: {year}")
        weights[year] = {key: float(row[key]) for key in ("wBB", "wHBP", "w1B", "w2B", "w3B", "wHR")}
        if not all(math.isfinite(value) and value >= 0 for value in weights[year].values()):
            raise ValueError(f"Invalid weights for {year}")
    latest = max(int(row["yearID"]) for name in ("Batting", "Pitching") for row in tables[name])
    if latest != manifest["latest_season"]:
        raise ValueError("Latest season does not match explicit manifest pin")
    return tables, weights


def parse_selection(text):
    if not re.fullmatch(r"(batter|pitcher):[a-z0-9]+:[0-9]{4}", text):
        raise ValueError(f"Invalid card selector: {text!r}; expected role:playerID:YYYY")
    role, player, year = text.split(":")
    return role, player, int(year)


def build_catalog(tables, weights, selection):
    selected = sorted(set(selection))
    years = {year+offset for _, _, year in selected for offset in (0, 1)}
    relevant = {name: [row for row in tables[name] if int(row["yearID"]) in years and row["lgID"] in ("AL", "NL")]
                for name in ("Batting", "Pitching")}
    contexts = league_context(relevant["Batting"], relevant["Pitching"])
    teams = {(int(row["yearID"]), row["teamID"]): row.get("BPF") for row in tables["Teams"]}
    people = {row["playerID"]: " ".join(filter(None, (row.get("nameFirst"), row.get("nameLast")))) for row in tables["People"]}
    groups = defaultdict(list)
    seen = set()
    for role, table in (("batter", "Batting"), ("pitcher", "Pitching")):
        for row in relevant[table]:
            key = (role, row["playerID"], int(row["yearID"]))
            stint = (*key, str(row["stint"]))
            if stint in seen:
                raise ValueError(f"Duplicate stint: {stint}")
            seen.add(stint)
            groups[key].append(row)
    cache = {}

    def season(key):
        if key in cache:
            return cache[key]
        role, player, year = key
        if role not in STATE_METRICS or key not in groups:
            raise ValueError(f"Selected season absent from AL/NL inputs: {key}")
        rows = sorted(groups[key], key=lambda row: (str(row["stint"]), row["teamID"]))
        if role == "batter":
            metrics, warnings = contextual_batter(rows, weights.get(year), contexts, teams)
            sample = dict(minimum=200, value=metrics["pa"], unit="PA")
        else:
            metrics, warnings = pitcher_metrics(rows, contexts)
            sample = dict(minimum=50, value=metrics["ip"], unit="IP")
        sample["qualified"] = sample["value"] is not None and sample["value"] >= sample["minimum"]
        if not sample["qualified"]:
            warnings.append("Below minimum sample or sample unavailable")
        if not people.get(player):
            raise ValueError(f"People name unavailable: {player}")
        # Construct, never copy the outer card: identity/year/outcomes cannot enter state.
        state = {"role": role, "metrics": {key: metrics[key] for key in STATE_METRICS[role]},
                 "sample": {"minimum": sample["minimum"], "value": sample["value"]}}
        card = dict(id=f"{role}:{player}:{year}", role=role, player_id=player,
                    player_name=people[player], year=year, metrics=metrics, sample=sample,
                    warnings=sorted(set(warnings)), judgment_state=state, oracle=None)
        cache[key] = card
        return card

    cards = []
    for key in selected:
        card = season(key)
        role, player, year = key
        metric, target, threshold = (("ops_plus", "ops_plus_drop_ge_10_next", 10) if role == "batter"
                                     else ("fip", "fip_rise_ge_0_50_next", .5))
        next_key = (role, player, year+1)
        if next_key in groups:
            following = season(next_key)
            current, future = card["metrics"][metric], following["metrics"][metric]
            if card["sample"]["qualified"] and following["sample"]["qualified"] and current is not None and future is not None:
                difference = current-future if role == "batter" else future-current
                card["oracle"] = dict(year=year+1, metric=metric, value=future,
                                      label=difference >= threshold, target=target)
        cards.append(card)
    # Reject NaN/Infinity at the boundary even for programmatic callers.
    json_bytes(cards)
    return cards


def quote(identifier):
    return '"'+identifier.replace('"', '""')+'"'


def write_database(path, tables, provenance, cards):
    """Fresh deterministic DB; raw TEXT retains blanks and export spellings."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
    try:
        with sqlite3.connect(temporary) as db:
            db.execute("PRAGMA user_version=1")
            for name, rows in sorted(tables.items()):
                columns = list(rows[0])
                db.execute(f"CREATE TABLE {quote(name)} ({', '.join(quote(key)+' TEXT' for key in columns)})")
                db.executemany(f"INSERT INTO {quote(name)} VALUES ({','.join('?' for _ in columns)})",
                               [[row.get(key) for key in columns] for row in rows])
                if name in ("Batting", "Pitching"):
                    db.execute(f"CREATE INDEX {quote(name+'_player_year')} ON {quote(name)} (playerID, yearID)")
                    db.execute(f"CREATE INDEX {quote(name+'_league_year')} ON {quote(name)} (lgID, yearID)")
                elif name == "Teams":
                    db.execute('CREATE UNIQUE INDEX teams_year_team ON "Teams" (yearID, teamID)')
                elif name == "People":
                    db.execute('CREATE UNIQUE INDEX people_player ON "People" (playerID)')
            db.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            db.executemany("INSERT INTO metadata VALUES (?,?)", [(key, json_bytes(value).decode().strip()) for key, value in sorted(provenance.items())])
            db.execute("CREATE TABLE cards (id TEXT PRIMARY KEY, role TEXT NOT NULL, player_id TEXT NOT NULL, year INTEGER NOT NULL, payload TEXT NOT NULL)")
            db.executemany("INSERT INTO cards VALUES (?,?,?,?,?)", [(c["id"], c["role"], c["player_id"], c["year"], json_bytes(c).decode().strip()) for c in cards])
            db.execute("CREATE INDEX cards_player_year ON cards (player_id, year)")
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("SQLite integrity check failed")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "build"))
    parser.add_argument("--manifest", type=Path, default=ROOT/"data/sources.json")
    parser.add_argument("--raw-dir", type=Path, default=ROOT/"data/lahman")
    parser.add_argument("--weights", type=Path, default=ROOT/"data/woba_weights.csv")
    parser.add_argument("--database", type=Path, default=ROOT/"data/lahman/lahman.sqlite3")
    parser.add_argument("--output", type=Path, default=ROOT/"priv/data/cards.json")
    parser.add_argument("--selection", type=Path, default=ROOT/"data/catalog.json")
    parser.add_argument("--select", action="append", help="role:playerID:YYYY; repeat; replaces default selection")
    parser.add_argument("--offline", action="store_true", help="forbid network, including during fetch")
    args = parser.parse_args(argv)
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get("manifest_version") != 1 or set(manifest["sources"]) != {"Batting", "Pitching", "Teams", "People"}:
        raise ValueError("Unsupported source manifest")
    tables, weights = prepare_inputs(manifest, args.raw_dir, args.weights, args.offline or args.command == "build")
    if args.command == "fetch":
        print(json.dumps({"verified_rows": {name: len(rows) for name, rows in tables.items()}, "weights_years": len(weights)}))
        return
    selectors = args.select if args.select is not None else json.loads(args.selection.read_text())["cards"]
    cards = build_catalog(tables, weights, [parse_selection(text) for text in selectors])
    provenance = dict(manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(), sources=manifest["sources"],
                      weights=manifest["weights"], latest_season=manifest["latest_season"], license=manifest["license"],
                      license_url=manifest["license_url"], notice_url=manifest["notice_url"], formula_version=FORMULA_VERSION,
                      scope="AL/NL", purpose="Selected demonstration; not an evaluation holdout", oracle_policy="Retrospective only; both seasons must meet PA>=200 or IP>=50")
    catalog = dict(schema_version=1, provenance=provenance, cards=cards)
    encoded = json_bytes(catalog)
    write_database(args.database, tables, provenance, cards)
    atomic_write(args.output, encoded)
    print(json.dumps({"cards": len(cards), "catalog": str(args.output), "sha256": hashlib.sha256(encoded).hexdigest(), "database": str(args.database)}))


if __name__ == "__main__":
    main()
