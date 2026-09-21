"""Committed real catalog contract; SQL cross-checks run when local data exists.

No synthetic fixtures in this module and no network. Missing bulk inputs skip
only the integration checks, not the committed artifact/weight checks.
"""
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DATABASE = ROOT/"data/lahman/lahman.sqlite3"
RAW = ROOT/"data/lahman"


class CommittedArtifactTests(unittest.TestCase):
    def test_exact_catalog_contract_and_numeric_state_allowlist(self):
        payload = json.loads((ROOT/"priv/data/cards.json").read_text())
        self.assertEqual(set(payload), {"schema_version", "provenance", "cards"})
        self.assertEqual(payload["schema_version"], 1)
        selection = json.loads((ROOT/"data/catalog.json").read_text())["cards"]
        self.assertEqual([c["id"] for c in payload["cards"]], sorted(selection))
        self.assertEqual(len(selection), len(set(selection)))
        for c in payload["cards"]:
            self.assertEqual(set(c), {"id", "role", "player_id", "player_name", "year", "metrics", "sample", "warnings", "judgment_state", "oracle"})
            self.assertEqual(c["id"], f'{c["role"]}:{c["player_id"]}:{c["year"]}')
            self.assertEqual(set(c["sample"]), {"qualified", "minimum", "value", "unit"})
            self.assertIs(type(c["sample"]["qualified"]), bool)
            self.assertEqual(set(c["judgment_state"]), {"role", "metrics", "sample"})
            self.assertEqual(set(c["judgment_state"]["sample"]), {"minimum", "value"})
            self.assertEqual(c["judgment_state"]["metrics"], c["metrics"])
            for key, value in c["metrics"].items():
                self.assertRegex(key, r"^[a-z][a-z0-9_]*$")
                self.assertTrue(value is None or (type(value) in (int, float) and math.isfinite(value)))
            if c["oracle"]:
                self.assertEqual(set(c["oracle"]), {"year", "metric", "value", "label", "target"})
                self.assertEqual(c["oracle"]["year"], c["year"]+1)
                self.assertIs(type(c["oracle"]["label"]), bool)
            if c["year"] == payload["provenance"]["latest_season"]:
                self.assertIsNone(c["oracle"])
        self.assertEqual({c["role"] for c in payload["cards"]}, {"batter", "pitcher"})
        self.assertEqual({c["sample"]["qualified"] for c in payload["cards"]}, {True, False})

    def test_frozen_weights_exact_bytes_and_provenance(self):
        manifest_bytes = (ROOT/"data/sources.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        provenance = json.loads((ROOT/"priv/data/cards.json").read_text())["provenance"]
        self.assertEqual(hashlib.sha256((ROOT/"data/woba_weights.csv").read_bytes()).hexdigest(), manifest["weights"]["sha256"])
        self.assertEqual(provenance["manifest_sha256"], hashlib.sha256(manifest_bytes).hexdigest())
        self.assertEqual(provenance["sources"], manifest["sources"])
        self.assertEqual(provenance["weights"], manifest["weights"])


@unittest.skipUnless(DATABASE.exists(), "run make fetch data for local SQLite integration checks")
class RealSQLiteTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True)
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.payload = json.loads((ROOT/"priv/data/cards.json").read_text())
        with (ROOT/"data/woba_weights.csv").open(newline="") as stream:
            self.weights = {int(r["Season"]): r for r in csv.DictReader(stream)}

    def sums(self, table, where, args):
        # Independent SQL aggregation, not imports of production metric code.
        keys = ("AB", "H", "X2B", "X3B", "HR", "BB", "SO", "HBP", "SF", "SH", "IBB") if table == "Batting" else ("IPouts", "ER", "HR", "BB", "HBP", "SO", "BFP")
        expressions = ",".join(f'SUM(CAST("{k}" AS INTEGER)) AS "{k}"' for k in keys)
        return dict(self.db.execute(f'SELECT {expressions} FROM "{table}" WHERE {where}', args).fetchone())

    @staticmethod
    def batting(c):
        a, h, b, hp, sf = c["AB"], c["H"], c["BB"], c["HBP"], c["SF"]
        singles = h-c["X2B"]-c["X3B"]-c["HR"]
        tb = h+c["X2B"]+2*c["X3B"]+3*c["HR"]
        pa = a+b+hp+sf+c["SH"]
        return dict(pa=pa, obp=(h+b+hp)/(a+b+hp+sf), slg=tb/a,
                    iso=(tb-h)/a, babip=(h-c["HR"])/(a-c["SO"]-c["HR"]+sf),
                    bb_pct=b/pa, k_pct=c["SO"]/pa), singles

    def expected(self, role, player, year):
        table = "Batting" if role == "batter" else "Pitching"
        where = 'playerID=? AND yearID=? AND lgID IN (\'AL\',\'NL\')'
        args = (player, year)
        c = self.sums(table, where, args)
        rows = self.db.execute(f'SELECT * FROM "{table}" WHERE {where}', args).fetchall()
        if role == "batter":
            m, singles = self.batting(c)
            w = self.weights[year]
            events = (c["BB"]-c["IBB"], c["HBP"], singles, c["X2B"], c["X3B"], c["HR"])
            m["woba"] = sum(float(w[key])*value for key, value in zip(("wBB", "wHBP", "w1B", "w2B", "w3B", "wHR"), events))/(c["AB"]+c["BB"]-c["IBB"]+c["HBP"]+c["SF"])
            m["ops"] = m["obp"]+m["slg"]
            context = dict(league_obp=0, league_slg=0, bpf=0)
            for r in rows:
                pa = sum(int(r[k]) for k in ("AB", "BB", "HBP", "SF", "SH"))
                lg, _ = self.batting(self.sums(table, "yearID=? AND lgID=?", (year, r["lgID"])))
                context["league_obp"] += lg["obp"]*pa/m["pa"]
                context["league_slg"] += lg["slg"]*pa/m["pa"]
                park = self.db.execute('SELECT BPF FROM Teams WHERE yearID=? AND teamID=?', (year, r["teamID"])).fetchone()[0]
                context["bpf"] += float(park)*pa/m["pa"]
            m.update(league_obp=context["league_obp"], league_slg=context["league_slg"], park_adjustment=(1+context["bpf"]/100)/2)
            m["ops_plus"] = 100*(m["obp"]/(m["league_obp"]*m["park_adjustment"])+m["slg"]/(m["league_slg"]*m["park_adjustment"])-1)
            return m
        outs = c["IPouts"]
        m = dict(ip=outs/3, era=27*c["ER"]/outs, k_bb_pct=(c["SO"]-c["BB"])/c["BFP"],
                 hr_per_9=27*c["HR"]/outs, bb_per_9=27*c["BB"]/outs, k_per_9=27*c["SO"]/outs, league_cfip=0)
        for r in rows:
            lg = self.sums(table, "yearID=? AND lgID=?", (year, r["lgID"]))
            cfip = 27*lg["ER"]/lg["IPouts"]-(13*lg["HR"]+3*(lg["BB"]+lg["HBP"])-2*lg["SO"])/(lg["IPouts"]/3)
            m["league_cfip"] += cfip*int(r["IPouts"])/outs
        m["fip"] = (13*c["HR"]+3*(c["BB"]+c["HBP"])-2*c["SO"])/m["ip"]+m["league_cfip"]
        return m

    def test_every_real_metric_and_oracle_against_independent_sql_counts(self):
        for card in self.payload["cards"]:
            with self.subTest(card=card["id"]):
                expected = self.expected(card["role"], card["player_id"], card["year"])
                self.assertEqual(set(expected), set(card["metrics"]))
                for key, value in expected.items():
                    self.assertAlmostEqual(card["metrics"][key], value, places=10, msg=key)
                sample_key = "pa" if card["role"] == "batter" else "ip"
                self.assertEqual(card["sample"]["value"], expected[sample_key])
                oracle = card["oracle"]
                if oracle:
                    future = self.expected(card["role"], card["player_id"], card["year"]+1)
                    metric = oracle["metric"]
                    self.assertAlmostEqual(oracle["value"], future[metric], places=10)
                    difference = expected[metric]-future[metric] if card["role"] == "batter" else future[metric]-expected[metric]
                    self.assertEqual(oracle["label"], difference >= (10 if card["role"] == "batter" else .5))

    def test_pinned_raw_rows_indexes_and_database_payload(self):
        manifest = json.loads((ROOT/"data/sources.json").read_text())
        for name, spec in manifest["sources"].items():
            self.assertEqual(hashlib.sha256((RAW/f"{name}.csv").read_bytes()).hexdigest(), spec["sha256"])
            self.assertEqual(self.db.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0], spec["rows"])
            self.assertTrue(self.db.execute(f'PRAGMA index_list("{name}")').fetchall())
        cards = [json.loads(r[0]) for r in self.db.execute("SELECT payload FROM cards ORDER BY id")]
        self.assertEqual(cards, self.payload["cards"])
        self.assertEqual(self.db.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_offline_rebuild_has_identical_catalog_and_sqlite_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, database = Path(tmp)/"cards.json", Path(tmp)/"lahman.sqlite3"
            completed = subprocess.run([sys.executable, "-m", "scripts.etl", "build", "--offline", "--output", str(output), "--database", str(database)], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(output.read_bytes(), (ROOT/"priv/data/cards.json").read_bytes())
            self.assertEqual(hashlib.sha256(database.read_bytes()).digest(), hashlib.sha256(DATABASE.read_bytes()).digest())


if __name__ == "__main__":
    unittest.main()
