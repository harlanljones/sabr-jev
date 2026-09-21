"""Offline synthetic counting rows; these are not app recordings."""
import importlib
import json
import unittest


def module(name):
    try:
        return importlib.import_module(name)
    except ModuleNotFoundError:
        return None


def batting(**changes):
    row = dict(playerID="test", yearID=2024, lgID="AL", teamID="AAA", stint=1,
               AB=100, H=30, X2B=5, X3B=1, HR=4, BB=10, SO=20,
               HBP=2, SF=3, SH=1, IBB=1)
    return row | changes


WEIGHTS = {"wBB": .7, "wHBP": .73, "w1B": .9, "w2B": 1.25,
           "w3B": 1.6, "wHR": 2.0}


class BatterTests(unittest.TestCase):
    def test_counting_metrics_sum_stints_before_rates(self):
        m = module("scripts.metrics")
        self.assertIsNotNone(m, "metrics implementation is missing")
        result, warnings = m.batter_metrics([batting(), batting(AB=50, H=15)], WEIGHTS)
        self.assertEqual(result["pa"], 182)
        self.assertAlmostEqual(result["obp"], 69 / 180)
        self.assertAlmostEqual(result["slg"], 83 / 150)
        self.assertAlmostEqual(result["iso"], 38 / 150)
        self.assertAlmostEqual(result["babip"], 37 / 108)
        self.assertAlmostEqual(result["bb_pct"], 20 / 182)
        self.assertAlmostEqual(result["k_pct"], 40 / 182)
        self.assertAlmostEqual(result["woba"], (.7*18+.73*4+.9*25+1.25*10+1.6*2+2*8)/178)
        self.assertEqual(warnings, [])


class MissingAndInvalidTests(unittest.TestCase):
    def test_zero_denominators_and_missing_weights_are_null(self):
        m = module("scripts.metrics")
        row = batting(**{key: 0 for key in ("AB", "H", "X2B", "X3B", "HR", "BB", "SO", "HBP", "SF", "SH", "IBB")})
        result, warnings = m.batter_metrics([row], None)
        self.assertIsNone(result["woba"])
        self.assertIsNone(result["obp"])
        self.assertIsNone(result["babip"])
        self.assertIn("wOBA weights unavailable", warnings)
        json.dumps(result, allow_nan=False)

    def test_optional_missing_is_zero_with_warning(self):
        result, warnings = module("scripts.metrics").batter_metrics([batting(HBP="", IBB=None, SF="NA")], WEIGHTS)
        self.assertEqual(result["pa"], 111)
        self.assertEqual(len(warnings), 3)

    def test_missing_core_does_not_invent_metrics(self):
        result, warnings = module("scripts.metrics").batter_metrics([batting(AB="")], WEIGHTS)
        self.assertIsNone(result["pa"])
        self.assertIsNone(result["woba"])
        self.assertTrue(warnings)

    def test_invalid_counts_rejected(self):
        for changes in ({"AB": -1}, {"H": 101}, {"SO": 101}, {"IBB": 11}, {"HR": 31}, {"BB": "nan"}, {"H": 2.5}, {"SO": 95}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module("scripts.metrics").batter_metrics([batting(**changes)], WEIGHTS)


def pitching(**changes):
    return dict(playerID="pitch", yearID=2024, lgID="AL", teamID="AAA", stint=1,
                IPouts=180, ER=20, HR=6, BB=15, HBP=2, SO=60, BFP=250) | changes


class ContextTests(unittest.TestCase):
    def test_invalid_known_counts_fail_even_when_other_core_missing(self):
        m = module("scripts.metrics")
        for changes in ({"H": 101, "SO": None}, {"SO": 101, "H": None}, {"HR": 31, "X2B": None}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                m.batter_metrics([batting(**changes)], WEIGHTS)

    def test_pitcher_inconsistent_bfp_counts_fail(self):
        m = module("scripts.metrics")
        for changes in ({"BFP": 50}, {"BB": -1}, {"SO": "inf"}, {"H": 2, "HR": 3}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                m.pitcher_metrics([pitching(**changes)], {})

    def test_oracle_input_year_weights_never_substitute_nearby_year(self):
        from scripts.etl import build_catalog
        from test_pipeline import tables
        card = build_catalog(tables(), {2025: WEIGHTS}, [("batter", "test", 2024)])[0]
        self.assertIsNone(card["metrics"]["woba"])
        self.assertIn("wOBA weights unavailable", card["warnings"])

    def test_all_league_rows_are_summed_not_average_or_filtered(self):
        m = module("scripts.metrics")
        self.assertTrue(hasattr(m, "league_context"))
        context = m.league_context([batting(), batting(playerID="small", AB=10, H=1, SO=2, HR=0, X2B=0, X3B=0)], [pitching()])
        self.assertAlmostEqual(context[(2024, "AL")]["obp"], 55/140)
        self.assertAlmostEqual(context[(2024, "AL")]["slg"], 50/110)
        result, warnings = m.contextual_batter([batting()], WEIGHTS, context, {(2024, "AAA"): 110})
        expected = 100*((42/115)/((55/140)*1.05) + .49/((50/110)*1.05)-1)
        self.assertAlmostEqual(result["ops_plus"], expected)
        self.assertEqual(warnings, [])

    def test_traded_batter_context_is_pa_weighted(self):
        m = module("scripts.metrics")
        self.assertTrue(hasattr(m, "contextual_batter"))
        contexts = {(2024, "AL"): dict(obp=.3, slg=.4, warnings=[]), (2024, "NL"): dict(obp=.4, slg=.5, warnings=[])}
        rows = [batting(), batting(lgID="NL", teamID="BBB", AB=200, H=60, SO=40)]
        result, _ = m.contextual_batter(rows, WEIGHTS, contexts, {(2024, "AAA"): 90, (2024, "BBB"): 110})
        self.assertAlmostEqual(result["league_obp"], (.3*116+.4*216)/332)
        self.assertAlmostEqual(result["park_adjustment"], (1+(90*116+110*216)/332/100)/2)
        unavailable, warnings = m.contextual_batter(rows, WEIGHTS, contexts, {(2024, "AAA"): 90})
        self.assertIsNone(unavailable["ops_plus"])
        self.assertTrue(warnings)

    def test_pitcher_outs_fip_and_bfp(self):
        m = module("scripts.metrics")
        self.assertTrue(hasattr(m, "pitcher_metrics"))
        contexts = m.league_context([], [pitching(), pitching(playerID="other", IPouts=3, ER=1, SO=0, HR=0, BB=0, HBP=0)])
        self.assertAlmostEqual(contexts[(2024, "AL")]["cfip"], 27*21/183-(13*6+3*17-2*60)/(183/3))
        result, _ = m.pitcher_metrics([pitching()], contexts)
        self.assertEqual(result["ip"], 60)
        self.assertEqual(result["era"], 3)
        self.assertAlmostEqual(result["fip"], (13*6+3*17-2*60)/60+contexts[(2024, "AL")]["cfip"])
        self.assertEqual(result["k_bb_pct"], 45/250)
        self.assertEqual(result["hr_per_9"], .9)
        self.assertEqual(result["bb_per_9"], 2.25)
        self.assertEqual(result["k_per_9"], 9)
        missing, warnings = m.pitcher_metrics([pitching(BFP="")], contexts)
        self.assertIsNone(missing["k_bb_pct"])
        self.assertIsNotNone(missing["fip"])
        self.assertTrue(warnings)

    def test_traded_pitcher_weights_by_outs_not_bfp(self):
        m = module("scripts.metrics")
        self.assertTrue(hasattr(m, "pitcher_metrics"))
        contexts = {(2024, "AL"): dict(cfip=3, warnings=[]), (2024, "NL"): dict(cfip=4, warnings=[])}
        result, _ = m.pitcher_metrics([pitching(), pitching(IPouts=90, lgID="NL", BFP=500)], contexts)
        self.assertAlmostEqual(result["league_cfip"], 10/3)
        zero, _ = m.pitcher_metrics([pitching(IPouts=0)], contexts)
        self.assertIsNone(zero["fip"])
        self.assertIsNone(zero["era"])


if __name__ == "__main__":
    unittest.main()
