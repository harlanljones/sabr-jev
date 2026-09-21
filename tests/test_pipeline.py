"""Pipeline contract tests use explicitly synthetic counting rows."""
import copy
import hashlib
import importlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from test_data import batting, pitching, WEIGHTS


def etl(test):
    try:
        return importlib.import_module("scripts.etl")
    except ModuleNotFoundError:
        test.fail("ETL implementation missing")


def tables():
    return {
        "Batting": [batting(AB=300, H=90), batting(AB=300, H=60, yearID=2025),
                    batting(playerID="other", AB=300, H=90), batting(playerID="other", AB=300, H=90, yearID=2025)],
        "Pitching": [pitching(), pitching(yearID=2025, ER=35, HR=15)],
        "Teams": [dict(yearID=year, teamID="AAA", BPF=100) for year in (2024, 2025)],
        "People": [dict(playerID="test", nameFirst="Synthetic", nameLast="Batter"),
                   dict(playerID="pitch", nameFirst="Synthetic", nameLast="Pitcher")],
    }


class PipelineTests(unittest.TestCase):
    def test_checksum_mismatch_never_uses_or_overwrites_cache(self):
        e = etl(self)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"input.csv"
            path.write_bytes(b"corrupt")
            spec = dict(url="https://example.invalid/pinned.csv", sha256=hashlib.sha256(b"good").hexdigest())
            with patch("urllib.request.urlopen") as network:
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    e.ensure_input(spec, path, offline=False)
                network.assert_not_called()
            self.assertEqual(path.read_bytes(), b"corrupt")

    def test_verified_cache_offline_and_missing_cache_refused(self):
        e = etl(self)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"input.csv"
            spec = dict(url="https://example.invalid/pin.csv", sha256=hashlib.sha256(b"good").hexdigest())
            with patch("urllib.request.urlopen") as network:
                with self.assertRaises(FileNotFoundError):
                    e.ensure_input(spec, path, offline=True)
                path.write_bytes(b"good")
                e.ensure_input(spec, path, offline=True)
                network.assert_not_called()

    def test_oracle_thresholds_qualification_and_state_allowlist(self):
        e = etl(self)
        cards = e.build_catalog(tables(), {2024: WEIGHTS, 2025: WEIGHTS},
                                [("batter", "test", 2024), ("pitcher", "pitch", 2024), ("batter", "test", 2025)])
        for card in cards:
            self.assertEqual(set(card["judgment_state"]), {"role", "metrics", "sample"})
            self.assertEqual(set(card["judgment_state"]["sample"]), {"minimum", "value"})
            self.assertEqual(card["judgment_state"]["metrics"], card["metrics"])
            if card["year"] == 2025:
                self.assertIsNone(card["oracle"])
            else:
                self.assertEqual(card["oracle"]["year"], 2025)
                self.assertTrue(card["oracle"]["label"])
        source = tables()
        source["Batting"][1] = batting(yearID=2025, AB=100, H=20)
        small = e.build_catalog(source, {2024: WEIGHTS, 2025: WEIGHTS}, [("batter", "test", 2024)])[0]
        self.assertIsNone(small["oracle"])

    def test_next_year_changes_cannot_change_judgment_state(self):
        e = etl(self)
        original = tables()
        changed = copy.deepcopy(original)
        changed["Batting"][1]["H"] = 150
        selection = [("batter", "test", 2024)]
        a = e.build_catalog(original, {2024: WEIGHTS, 2025: WEIGHTS}, selection)[0]
        b = e.build_catalog(changed, {2024: WEIGHTS, 2025: WEIGHTS}, selection)[0]
        self.assertEqual(a["judgment_state"], b["judgment_state"])
        self.assertNotEqual(a["oracle"], b["oracle"])
        self.assertNotIn("year", json.dumps(a["judgment_state"]))

    def test_determinism_and_selection_validation(self):
        e = etl(self)
        source = tables()
        selection = [("batter", "test", 2024), ("pitcher", "pitch", 2024)]
        a = e.build_catalog(source, {2024: WEIGHTS, 2025: WEIGHTS}, selection)
        b = e.build_catalog({key: list(reversed(rows)) for key, rows in source.items()},
                            {2025: WEIGHTS, 2024: WEIGHTS}, list(reversed(selection)))
        self.assertEqual(e.json_bytes(a), e.json_bytes(b))
        with self.assertRaises(ValueError):
            e.build_catalog(source, {}, [("batter", "absent", 2024)])
        with self.assertRaises(ValueError):
            e.build_catalog(source, {}, [("other", "test", 2024)])

    def test_sqlite_sources_indexes_and_metadata(self):
        e = etl(self)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"test.sqlite3"
            e.write_database(path, tables(), {"formula_version": "test"}, [])
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM "Batting"').fetchone()[0], 4)
                self.assertTrue(db.execute('PRAGMA index_list("Batting")').fetchall())
                self.assertEqual(json.loads(db.execute("SELECT value FROM metadata WHERE key='formula_version'").fetchone()[0]), "test")
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")


if __name__ == "__main__":
    unittest.main()
