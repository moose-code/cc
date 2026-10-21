#!/usr/bin/env python3
"""No network checks of script/phase2/calibrate.py: the row arithmetic, the flags and the recommendation rule, with
injected quotes. run with `python3 -I script/phase2/test_calibrate.py`."""

import importlib.util
from pathlib import Path
import sys
import unittest

# the repo ignores no __pycache__; the module is loaded without writing bytecode next to it
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("calibrate", HERE / "calibrate.py")
cal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cal)

WEI = 10**18
SUPPLY = 10**27
GAS = 600_000 * 50 * 10**9  # 0.03 ETH


def linear_buy(price_wei_per_cc, impact_bps_per_pct=0):
    """ETH in for x CC out: a unit price that worsens by `impact_bps_per_pct` for each percent of supply bought."""

    def quote(x):
        pct = x * 100 // SUPPLY
        unit = price_wei_per_cc * (10_000 + impact_bps_per_pct * pct) // 10_000
        return x * unit // WEI

    return quote


def linear_sell(price_wei_per_balance):
    return lambda y: y * price_wei_per_balance // WEI


class Arithmetic(unittest.TestCase):
    def test_pro_rata_floors_and_rejects_bad_sizes(self):
        # promise: PLAN section 7 Y = floor(x * C / S), the policy quote at fee 0
        self.assertEqual(cal.pro_rata(2, 7, 3), 4)
        self.assertEqual(cal.pro_rata(SUPPLY // 1000, 5 * WEI, SUPPLY), 5 * WEI // 1000)
        with self.assertRaises(ValueError):
            cal.pro_rata(0, 1, 1)
        with self.assertRaises(ValueError):
            cal.pro_rata(2, 1, 1)

    def test_row_profit_and_margin(self):
        # promise: PLAN section 7 profit = V - Q - G and margin = profit / (Q + G) per row, from the injected quotes
        rows = cal.compute_rows([1000 * WEI], [100], SUPPLY, linear_buy(10**12), linear_sell(10**17), GAS)
        self.assertEqual(len(rows), 1)
        r = rows[0]
        x = SUPPLY // 100
        self.assertEqual(r["x"], x)
        self.assertEqual(r["y"], 10 * WEI)
        self.assertEqual(r["q"], x * 10**12 // WEI)  # 10 ETH
        self.assertEqual(r["v"], 1 * WEI)  # 10 BALANCE at 0.1 ETH
        self.assertEqual(r["profit"], r["v"] - r["q"] - GAS)
        self.assertEqual(r["margin_bps"], r["profit"] * 10_000 // (r["q"] + GAS))
        self.assertEqual(r["status"], "ok")
        self.assertEqual(r["flags"], [])

    def test_stress_widens_both_legs(self):
        # promise: PLAN section 7 the slippage stress is applied to the buy and the sale, never as a fixed haircut on the quote itself
        plain = cal.compute_rows([1000 * WEI], [100], SUPPLY, linear_buy(10**12), linear_sell(10**17), GAS)[0]
        stressed = cal.compute_rows([1000 * WEI], [100], SUPPLY, linear_buy(10**12), linear_sell(10**17), GAS, 100)[0]
        self.assertEqual(stressed["q"], plain["q"], "the quotes themselves are untouched")
        self.assertEqual(stressed["profit"], plain["v"] * 9_900 // 10_000 - plain["q"] * 10_100 // 10_000 - GAS)

    def test_uninitialized_pool_and_unsupported_sizes_are_marked_not_priced(self):
        # promise: PLAN section 7 a pool that is not initialized is marked, no price is invented, and a failing quote flags the size
        rows = cal.compute_rows([1000 * WEI], [10, 50], SUPPLY, linear_buy(10**12), lambda y: None, GAS)
        for r in rows:
            self.assertEqual(r["status"], "pool not initialized")
            self.assertIsNone(r["v"])
            self.assertIsNone(r["profit"])
            self.assertIsNotNone(r["q"], "the CC leg is still quoted")

        def buy(x):
            if x > SUPPLY // 200:
                raise cal.QuoteRevert("execution reverted: not enough liquidity")
            return x * 10**12 // WEI

        rows = cal.compute_rows([1000 * WEI], [10, 100], SUPPLY, buy, linear_sell(10**17), GAS)
        self.assertEqual(rows[0]["status"], "ok")
        self.assertEqual(rows[1]["status"], "unsupported size")
        self.assertIsNone(rows[1]["q"])
        self.assertTrue(any("unsupported" in f for f in rows[1]["flags"]))

    def test_thin_liquidity_flag(self):
        # promise: PLAN section 7 thin liquidity is flagged from the unit price impact against the smallest supported size
        rows = cal.compute_rows([1000 * WEI], [10, 100], SUPPLY, linear_buy(10**12, 1_000), linear_sell(10**17), GAS)
        self.assertEqual(rows[0]["flags"], [])
        self.assertIn("thin CC liquidity", rows[1]["flags"])

    def test_zero_claim_row(self):
        # promise: a claim that rounds to zero is reported instead of priced
        rows = cal.compute_rows([1], [10], SUPPLY, linear_buy(10**12), linear_sell(10**17), GAS)
        self.assertEqual(rows[0]["status"], "zero claim")

    def test_backing_on_both_denominators(self):
        # promise: PLAN section 7 backing per token is printed on the total and the circulating supply
        on_total, on_circ = cal.backing(100 * WEI, SUPPLY, SUPPLY // 5)
        self.assertEqual(on_total, 100 * WEI * WEI // SUPPLY)
        self.assertEqual(on_circ, 5 * on_total)
        self.assertEqual(cal.backing(1, SUPPLY, 0)[1], None)

    def test_working_after_floor(self):
        self.assertEqual(cal.working_after_floor(100, 30, 20), 50)
        self.assertEqual(cal.working_after_floor(100, 90, 20), 0)
        self.assertIsNone(cal.working_after_floor(None, 1, 1))

    def test_amount_parsing_and_formatting(self):
        self.assertEqual(cal.parse_amount("1.5"), 15 * 10**17)
        self.assertEqual(cal.parse_amount("1_000"), 1000 * WEI)
        self.assertEqual(cal.parse_amount("12.5", 9), 12_500_000_000)
        self.assertEqual(cal.fmt(15 * 10**17), "1.500000")
        self.assertEqual(cal.fmt(-1), "-0.000000")
        with self.assertRaises(ValueError):
            cal.parse_amount("-1")

    def test_pool_key_orders_currencies(self):
        key = cal.pool_key("0x00000000000000000000000000000000000000AA", cal.ZERO_ADDRESS, 3000, 30, cal.ZERO_ADDRESS)
        self.assertEqual(key["currency0"], cal.ZERO_ADDRESS)
        self.assertEqual(key["currency1"], "0x00000000000000000000000000000000000000aa")
        self.assertEqual(cal.key_tuple(key), f"({cal.ZERO_ADDRESS},0x00000000000000000000000000000000000000aa,3000,30,{cal.ZERO_ADDRESS})")


class Recommendation(unittest.TestCase):
    def rows(self, candidates, sell_price):
        return cal.compute_rows(candidates, [10, 50, 100], SUPPLY, linear_buy(10**12), linear_sell(sell_price), GAS)

    def test_smallest_candidate_meeting_the_backing_target_within_budget(self):
        # promise: PLAN section 7 the recommendation is the smallest C within budget and the maximum allocation that meets the backing target
        candidates = [100 * WEI, 1000 * WEI, 5000 * WEI, 20_000 * WEI]
        rows = self.rows(candidates, 10**17)
        target = cal.backing(1000 * WEI, SUPPLY, SUPPLY)[0]
        eligible, chosen, _ = cal.recommend(candidates, rows, 10_000 * WEI, None, target, "total", SUPPLY, SUPPLY, 200)
        self.assertEqual(eligible, [100 * WEI, 1000 * WEI, 5000 * WEI])
        self.assertEqual(chosen, 1000 * WEI)
        # the maximum allocation narrows the eligible set further
        _, chosen, _ = cal.recommend(candidates, rows, 10_000 * WEI, 500 * WEI, target, "total", SUPPLY, SUPPLY, 200)
        self.assertIsNone(chosen)
        # the circulating basis reaches the target with a smaller reserve
        _, chosen, _ = cal.recommend(candidates, rows, 10_000 * WEI, None, target, "circulating", SUPPLY, SUPPLY // 10, 200)
        self.assertEqual(chosen, 100 * WEI)

    def test_never_above_budget(self):
        # promise: PLAN section 7 the script never raises a candidate above budget, even when only a larger one meets the target
        candidates = [100 * WEI, 50_000 * WEI]
        rows = self.rows(candidates, 10**17)
        target = cal.backing(50_000 * WEI, SUPPLY, SUPPLY)[0]
        eligible, chosen, arbitrage = cal.recommend(candidates, rows, 1000 * WEI, None, target, "total", SUPPLY, SUPPLY, 200)
        self.assertEqual(eligible, [100 * WEI])
        self.assertIsNone(chosen)
        self.assertIsNone(arbitrage, "the arbitrage rows of the unbudgeted candidate do not count")

    def test_arbitrage_sentence(self):
        # promise: PLAN section 7 the report says either where an immediate arbitrage exists or that proportional claims remain useful
        candidates = [100 * WEI, 10_000 * WEI]
        # 1 percent of supply costs 10 ETH; C = 10000 gives Y = 100 BALANCE at 1 ETH each = 100 ETH: an arbitrage
        rows = self.rows(candidates, WEI)
        _, _, arbitrage = cal.recommend(candidates, rows, None, None, None, "total", SUPPLY, SUPPLY, 200)
        self.assertEqual(arbitrage, (10_000 * WEI, 10))
        self.assertIn("an immediate arbitrage exists at size 10 bps", cal.arbitrage_sentence(arbitrage))
        self.assertIn("C=10000.000000", cal.arbitrage_sentence(arbitrage))
        # at 0.001 ETH per BALANCE no row clears the margin
        rows = self.rows(candidates, 10**15)
        _, _, arbitrage = cal.recommend(candidates, rows, None, None, None, "total", SUPPLY, SUPPLY, 200)
        self.assertIsNone(arbitrage)
        self.assertEqual(cal.arbitrage_sentence(None),
                         "no budgeted reserve creates an immediate arbitrage; proportional claims remain useful")

    def test_arbitrage_needs_the_target_margin(self):
        # promise: a positive profit below the target margin is not called an arbitrage
        candidates = [10_000 * WEI]
        rows = self.rows(candidates, 10**17)  # 1 percent: Q 10 ETH, Y 100 BALANCE, V 10 ETH: profit is -G
        for r in rows:
            self.assertLess(r["margin_bps"], 200)
        _, _, arbitrage = cal.recommend(candidates, rows, None, None, None, "total", SUPPLY, SUPPLY, 200)
        self.assertIsNone(arbitrage)
        # a margin floor of -100 bps admits the 50 bps row (-0.03 ETH over 5.03 ETH) but not the 10 bps row
        _, _, arbitrage = cal.recommend(candidates, rows, None, None, None, "total", SUPPLY, SUPPLY, -100)
        self.assertEqual(arbitrage, (10_000 * WEI, 50))




class MarginRecommendation(unittest.TestCase):
    def test_smallest_eligible_reserve_meeting_the_margin_at_the_decision_size(self):
        rows = [
            {"candidate": 1000, "size_bps": 50, "status": "ok", "margin_bps": 100},
            {"candidate": 5000, "size_bps": 50, "status": "ok", "margin_bps": 250},
            {"candidate": 5000, "size_bps": 10, "status": "ok", "margin_bps": 900},
            {"candidate": 20000, "size_bps": 50, "status": "ok", "margin_bps": 900},
        ]
        self.assertEqual(cal.margin_recommendation(rows, [1000, 5000, 20000], 50, 200), 5000)
        self.assertIsNone(cal.margin_recommendation(rows, [1000], 50, 200), "never above budget")
        self.assertIsNone(cal.margin_recommendation(rows, [1000, 5000, 20000], 100, 200), "no row at that size")


if __name__ == "__main__":
    unittest.main()
