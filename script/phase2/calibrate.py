#!/usr/bin/env python3
"""Read only seed calibration of the phase 2 claim reserve (docs/reviews/PHASE2-PLAN-fd85ba5-2026-10-20.md section 7).

For each candidate reserve C and test size x (a share of the CC total supply S):
  Q = ETH to buy net x CC exact output through the hooked CC/ETH v4 pool, from the mainnet V4Quoter, which runs the
      hook, so the dynamic fee is inside the number and no fixed haircut is applied
  Y = floor(x * C / S), the pro rata claim at fee 0
  V = ETH from selling Y BALANCE exact input on the BALANCE pool, from the same quoter
  G = gas units * gas price
  profit = V - Q - G, margin = profit / (Q + G)
The report prints every row, flags sizes the pools cannot serve and thin liquidity, prints the backing per token on the
total and the circulating supply (total less the pool manager's holding), the working funds left after the floor,
the smallest candidate within budget that meets the backing target, and whether any budgeted reserve creates an
immediate arbitrage. Nothing is signed and nothing is sent: every read is an eth_call through `cast` at one pinned
block. A pool that is not initialized is reported as such; no price is invented for it.
"""

import argparse
from decimal import Decimal, ROUND_DOWN
import json
import os
import shutil
import subprocess
import sys

V4_QUOTER = "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203"
POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90"
CC_HOOK = "0x866F31562dDe70D7B989C2529a9deFFFFd3bE8CC"
CC_POOL_FEE = 8388608
CC_TICK_SPACING = 200
BALANCE_POOL_FEE = 3000
BALANCE_TICK_SPACING = 30
ZERO_ADDRESS = "0x" + "0" * 40
# the pools mapping slot of the v4 PoolManager (StateLibrary.POOLS_SLOT)
POOLS_SLOT = 6
POOL_NOT_INITIALIZED = "0x486aa307"
BPS = 10_000
WEI = 10**18
QUOTE_SINGLE = "(((address,address,uint24,int24,address),bool,uint128,bytes))(uint256,uint256)"


class RpcError(Exception):
    """A read failed for a reason other than a quote revert."""


class QuoteRevert(Exception):
    """The quoter reverted; `reason` is cast's message."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# ------------------------------------------------------------------ pure arithmetic


def parse_amount(text, decimals=18):
    """A decimal token amount as base units, rounded down."""
    value = Decimal(str(text).replace("_", ""))
    if value < 0:
        raise ValueError(f"negative amount {text}")
    return int((value * (10**decimals)).to_integral_value(rounding=ROUND_DOWN))


def fmt(units, decimals=18, places=6):
    """Base units as a decimal string with `places` places, rounded down, sign kept."""
    sign = "-" if units < 0 else ""
    q = Decimal(abs(units)) / (10**decimals)
    return sign + str(q.quantize(Decimal(1).scaleb(-places), rounding=ROUND_DOWN))


def pro_rata(x, reserve, supply):
    """ProRataRedemptionPolicy.quote at fee 0: floor(x * C / S)."""
    if supply == 0 or x == 0 or x > supply:
        raise ValueError("size must be between 1 and the supply")
    return x * reserve // supply


def stressed(q, v, stress_bps):
    """The slippage stress widens both legs: the buy costs more, the sale returns less."""
    return q * (BPS + stress_bps) // BPS, v * (BPS - stress_bps) // BPS


def compute_rows(candidates, sizes_bps, supply, quote_buy, quote_sell, gas_wei, stress_bps=0, thin_impact_bps=500):
    """One row per candidate and size. `quote_buy(x)` returns the ETH in for x CC out, `quote_sell(y)` the ETH out
    for y BALANCE in; either may raise QuoteRevert (the size is unsupported) or return None (the pool is not
    initialized). Thin liquidity is a unit price more than `thin_impact_bps` worse than at the smallest supported size
    of the same leg."""
    rows = []
    buy_cache = {}
    for size_bps in sizes_bps:
        x = supply * size_bps // BPS
        try:
            buy_cache[size_bps] = ("ok", quote_buy(x))
        except QuoteRevert as e:
            buy_cache[size_bps] = ("unsupported", e.reason)
    buy_base = _unit_base({s: r for s, r in buy_cache.items() if r[0] == "ok"}, supply)
    for reserve in candidates:
        sell_cache = {}
        for size_bps in sizes_bps:
            x = supply * size_bps // BPS
            y = pro_rata(x, reserve, supply)
            row = {"candidate": reserve, "size_bps": size_bps, "x": x, "y": y, "q": None, "v": None, "g": gas_wei,
                   "profit": None, "margin_bps": None, "flags": [], "status": "ok"}
            buy = buy_cache[size_bps]
            if buy[0] != "ok":
                row["status"] = "unsupported size"
                row["flags"].append(f"CC buy of {fmt(x)} CC unsupported: {buy[1]}")
            else:
                row["q"] = buy[1]
                if buy_base is not None and x and _impact_bps(buy[1], x, *buy_base) > thin_impact_bps:
                    row["flags"].append("thin CC liquidity")
            if y == 0:
                row["status"] = "zero claim"
                row["flags"].append("claim rounds to zero")
            else:
                try:
                    v = quote_sell(y)
                except QuoteRevert as e:
                    v = "unsupported"
                    row["status"] = "unsupported size"
                    row["flags"].append(f"BALANCE sale of {fmt(y)} unsupported: {e.reason}")
                if v is None:
                    row["status"] = "pool not initialized"
                    row["flags"].append("BALANCE pool not initialized")
                elif v != "unsupported":
                    row["v"] = v
                    sell_cache[y] = v
            if row["status"] == "ok":
                q, v = stressed(row["q"], row["v"], stress_bps)
                row["profit"] = v - q - gas_wei
                row["margin_bps"] = row["profit"] * BPS // (q + gas_wei) if q + gas_wei else None
            rows.append(row)
        base = _unit_base_sell(sell_cache)
        for row in rows:
            if row["candidate"] == reserve and row["v"] is not None and base is not None and row["y"]:
                if _impact_bps_sell(row["v"], row["y"], *base) > thin_impact_bps:
                    row["flags"].append("thin BALANCE liquidity")
    return rows


def _unit_base(ok_quotes, supply):
    if not ok_quotes:
        return None
    s = min(ok_quotes)
    return ok_quotes[s][1], supply * s // BPS


def _impact_bps(q, x, q0, x0):
    """How much worse the unit price q/x is than q0/x0, bps."""
    if q0 == 0 or x == 0:
        return 0
    return (q * x0 * BPS) // (q0 * x) - BPS


def _unit_base_sell(sell_cache):
    if not sell_cache:
        return None
    y0 = min(sell_cache)
    return sell_cache[y0], y0


def _impact_bps_sell(v, y, v0, y0):
    """How much less ETH per BALANCE the sale of y returns than the sale of y0, bps."""
    if v == 0 or y0 == 0:
        return BPS
    return BPS - (v * y0 * BPS) // (v0 * y)


def backing(reserve, total, circulating):
    """BALANCE per CC on both denominators, as 18 decimal base units."""
    on_total = reserve * WEI // total if total else 0
    on_circulating = reserve * WEI // circulating if circulating else None
    return on_total, on_circulating


def working_after_floor(budget, reserve, minimum_working):
    """What stays as free working funds when `reserve` is seeded from `budget` above the floor; None without a budget."""
    if budget is None:
        return None
    return max(budget - reserve - minimum_working, 0)


def recommend(candidates, rows, budget, max_allocation, backing_target, basis, total, circulating, target_margin_bps):
    """The recommendation rule of plan section 7: the smallest candidate within the budget and the maximum allocation
    that meets the backing target (on `basis`, "total" or "circulating"), and the immediate arbitrage sentence over
    the same eligible candidates. A candidate above the budget is never recommended."""
    eligible = [c for c in sorted(candidates) if (budget is None or c <= budget) and (max_allocation is None or c <= max_allocation)]
    chosen = None
    if backing_target is not None:
        for c in eligible:
            on_total, on_circ = backing(c, total, circulating)
            value = on_total if basis == "total" else on_circ
            if value is not None and value >= backing_target:
                chosen = c
                break
    arbitrage = None
    for row in sorted(rows, key=lambda r: (r["candidate"], r["size_bps"])):
        if row["candidate"] not in eligible or row["status"] != "ok":
            continue
        if row["margin_bps"] is not None and row["margin_bps"] >= target_margin_bps:
            arbitrage = (row["candidate"], row["size_bps"])
            break
    return eligible, chosen, arbitrage


def sanitize_url(url):
    """The scheme and host of an RPC URL, never its path, query or userinfo: endpoints carry keys there"""
    from urllib.parse import urlsplit
    try:
        u = urlsplit(url)
        return f"{u.scheme}://{u.hostname}" if u.scheme and u.hostname else "<rpc>"
    except ValueError:
        return "<rpc>"


def margin_recommendation(rows, eligible, decision_size_bps, target_margin_bps):
    """The second report output (decision 246 as amended): the smallest eligible reserve whose row at the decision
    size is supported and meets the target net margin, or None. It answers "would this motivate buying and redeeming at
    the tested size", apart from the backing target, and never recommends above the budget"""
    for c in sorted(eligible):
        for row in rows:
            if row["candidate"] == c and row["size_bps"] == decision_size_bps and row["status"] == "ok":
                if row["margin_bps"] is not None and row["margin_bps"] >= target_margin_bps:
                    return c
    return None


def arbitrage_sentence(arbitrage):
    if arbitrage is None:
        return "no budgeted reserve creates an immediate arbitrage; proportional claims remain useful"
    reserve, size_bps = arbitrage
    return f"an immediate arbitrage exists at size {size_bps} bps of supply for C={fmt(reserve)} BALANCE"


# ------------------------------------------------------------------ the chain, through cast


class Chain:
    """eth_call reads through `cast` at one pinned block. urllib cannot reach the RPC through this environment's
    proxy, a subprocess can."""

    def __init__(self, rpc_url, block, cast="cast"):
        self.rpc_url = rpc_url
        self.cast = shutil.which(cast) or cast
        if shutil.which(self.cast) is None:
            raise RpcError(f"{cast} is not on PATH; export PATH=\"$HOME/.foundry/bin:$PATH\"")
        self.block = block if block != "latest" else self._block_number()

    def _run(self, args):
        try:
            result = subprocess.run([self.cast, *args, "--rpc-url", self.rpc_url], text=True, capture_output=True)
        except OSError as e:
            raise RpcError(f"cannot run cast: {e}") from e
        return result

    def _block_number(self):
        result = self._run(["block-number"])
        if result.returncode:
            raise RpcError(f"RPC failure reading the block number: {result.stderr.strip() or result.stdout.strip()}")
        return int(result.stdout.strip())

    def call(self, to, sig, *args):
        """The decoded outputs of a call. Raises QuoteRevert on `execution reverted`, RpcError on anything else."""
        result = self._run(["call", "--json", to, sig, *args, "--block", str(self.block)])
        if result.returncode:
            message = _cast_error(result)
            if "execution reverted" in message:
                raise QuoteRevert(message)
            raise RpcError(f"RPC failure calling {to} {sig.split('(')[0]}: {message}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as e:
            raise RpcError(f"unreadable cast output for {sig}: {result.stdout[:200]}") from e

    def has_code(self, at):
        result = self._run(["code", at, "--block", str(self.block)])
        if result.returncode:
            raise RpcError(f"RPC failure reading code at {at}: {_cast_error(result)}")
        return result.stdout.strip() not in ("", "0x")

    def total_supply(self, token):
        return int(self.call(token, "totalSupply()(uint256)")[0])

    def balance_of(self, token, holder):
        return int(self.call(token, "balanceOf(address)(uint256)", holder)[0])

    def gas_price(self):
        result = self._run(["gas-price"])
        if result.returncode:
            raise RpcError(f"RPC failure reading the gas price: {_cast_error(result)}")
        return int(result.stdout.strip())

    def keccak(self, data):
        result = subprocess.run([self.cast, "keccak", data], text=True, capture_output=True)
        if result.returncode:
            raise RpcError(f"cast keccak failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def abi_encode(self, sig, *args):
        result = subprocess.run([self.cast, "abi-encode", sig, *args], text=True, capture_output=True)
        if result.returncode:
            raise RpcError(f"cast abi-encode failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def pool_id(self, key):
        return self.keccak(self.abi_encode("f((address,address,uint24,int24,address))", key_tuple(key)))

    def pool_initialized(self, key):
        """sqrtPriceX96 of the pool's slot0, read with extsload, is nonzero once the pool is initialized."""
        slot = self.keccak(self.abi_encode("f(bytes32,uint256)", self.pool_id(key), str(POOLS_SLOT)))
        word = self.call(POOL_MANAGER, "extsload(bytes32)(bytes32)", slot)[0]
        return int(word, 16) & ((1 << 160) - 1) != 0

    def quote_exact_output(self, key, zero_for_one, amount_out):
        params = f"({key_tuple(key)},{'true' if zero_for_one else 'false'},{amount_out},0x)"
        return int(self.call(V4_QUOTER, "quoteExactOutputSingle" + QUOTE_SINGLE, params)[0])

    def quote_exact_input(self, key, zero_for_one, amount_in):
        params = f"({key_tuple(key)},{'true' if zero_for_one else 'false'},{amount_in},0x)"
        return int(self.call(V4_QUOTER, "quoteExactInputSingle" + QUOTE_SINGLE, params)[0])


def _cast_error(result):
    text = result.stdout.strip() or result.stderr.strip()
    try:
        doc = json.loads(text)
        errors = doc.get("errors") or []
        if errors:
            return errors[0].get("message", text)
    except json.JSONDecodeError:
        pass
    return text.splitlines()[0] if text else "no output"


def pool_key(currency0, currency1, fee, tick_spacing, hooks):
    """A v4 pool key with the currencies in address order (native ETH, the zero address, is always currency0)."""
    a, b = currency0.lower(), currency1.lower()
    if int(a, 16) > int(b, 16):
        a, b = b, a
    return {"currency0": a, "currency1": b, "fee": int(fee), "tickSpacing": int(tick_spacing), "hooks": hooks.lower()}


def key_tuple(key):
    return f"({key['currency0']},{key['currency1']},{key['fee']},{key['tickSpacing']},{key['hooks']})"


# ------------------------------------------------------------------ the report


def print_rows(rows):
    print("candidate C (BALANCE) | size bps | x CC | Q ETH | Y BALANCE | V ETH | G ETH | profit ETH | margin bps | flags")
    for r in rows:
        cells = [fmt(r["candidate"]), str(r["size_bps"]), fmt(r["x"]),
                 fmt(r["q"]) if r["q"] is not None else "-", fmt(r["y"]),
                 fmt(r["v"]) if r["v"] is not None else "-", fmt(r["g"]),
                 fmt(r["profit"]) if r["profit"] is not None else "-",
                 str(r["margin_bps"]) if r["margin_bps"] is not None else "-",
                 "; ".join(r["flags"]) if r["flags"] else r["status"]]
        print(" | ".join(cells))


def print_backing(candidates, total, circulating, budget, minimum_working):
    print("backing per CC: C (BALANCE) | on total supply | on circulating supply (not redeemable) | working left after the floor")
    for c in sorted(candidates):
        on_total, on_circ = backing(c, total, circulating)
        left = working_after_floor(budget, c, minimum_working)
        print(" | ".join([fmt(c), fmt(on_total), fmt(on_circ) if on_circ is not None else "-",
                          fmt(left) if left is not None else "no budget given"]))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rpc-url", default=os.environ.get("RPC_URL"), help="the mainnet RPC (or RPC_URL)")
    p.add_argument("--block", default="latest", help="the pinned block of every read (default latest, resolved once)")
    p.add_argument("--cc", required=True, help="the CC coin")
    p.add_argument("--cc-pool-id", help="optional: the CC pool id to check the key against")
    p.add_argument("--cc-pool-hook", default=CC_HOOK)
    p.add_argument("--cc-pool-fee", type=int, default=CC_POOL_FEE, help="the dynamic fee flag of the CC pool")
    p.add_argument("--cc-pool-tick-spacing", type=int, default=CC_TICK_SPACING)
    p.add_argument("--balance-token", help="the BALANCE token; without it the sale leg is reported as unavailable")
    p.add_argument("--balance-pool-hook", default=ZERO_ADDRESS, help="the hook of the BALANCE/ETH pool (input)")
    p.add_argument("--balance-pool-fee", type=int, default=BALANCE_POOL_FEE)
    p.add_argument("--balance-pool-tick-spacing", type=int, default=BALANCE_TICK_SPACING)
    p.add_argument("--reserve-candidates", required=True, help="comma separated BALANCE amounts (token units)")
    p.add_argument("--max-allocation", help="the most BALANCE the operator would allocate to claims (token units)")
    p.add_argument("--budget", help="the BALANCE available in total (token units); never exceeded by a recommendation")
    p.add_argument("--minimum-working", default="0", help="minimumWorkingBalance F (token units)")
    p.add_argument("--test-sizes-bps", default="10,50,100", help="sizes as bps of the CC total supply")
    p.add_argument("--target-margin-bps", type=int, default=200)
    p.add_argument("--backing-target", help="BALANCE per CC the owner wants (token units per CC)")
    p.add_argument("--backing-basis", choices=["total", "circulating"], default="total",
                   help="the denominator of --backing-target; the redeemable share is always on the total supply")
    p.add_argument("--decision-size-bps", type=int, default=50,
                   help="the test size of the second recommendation, the reserve meeting --target-margin-bps there")
    p.add_argument("--gas-price-gwei", help="default: the node's gas price")
    p.add_argument("--gas-units", type=int, default=600_000, help="buy, approve, redeemCC and sell together")
    p.add_argument("--slippage-stress-bps", type=int, default=0, help="widens both legs by this much")
    p.add_argument("--thin-impact-bps", type=int, default=500, help="unit price impact that flags thin liquidity")
    a = p.parse_args(argv)
    if not a.rpc_url:
        p.error("--rpc-url or RPC_URL is required")

    candidates = sorted({parse_amount(c) for c in a.reserve_candidates.split(",") if c.strip()})
    sizes = sorted({int(s) for s in a.test_sizes_bps.split(",") if s.strip()})
    if not candidates or not sizes or any(s <= 0 or s > BPS for s in sizes):
        p.error("reserve candidates and sizes (1 to 10000 bps) are required")
    budget = parse_amount(a.budget) if a.budget else None
    max_allocation = parse_amount(a.max_allocation) if a.max_allocation else None
    backing_target = parse_amount(a.backing_target) if a.backing_target else None
    minimum_working = parse_amount(a.minimum_working)

    chain = Chain(a.rpc_url, a.block)
    print(f"block {chain.block}, rpc {sanitize_url(a.rpc_url)}")
    if not chain.has_code(V4_QUOTER):
        raise RpcError(f"the V4Quoter {V4_QUOTER} has no code at block {chain.block}; a quoter that does not run the hook is not substituted")
    if not chain.has_code(a.cc):
        raise RpcError(f"the CC coin {a.cc} has no code at block {chain.block}")
    cc_key = pool_key(ZERO_ADDRESS, a.cc, a.cc_pool_fee, a.cc_pool_tick_spacing, a.cc_pool_hook)
    cc_id = chain.pool_id(cc_key)
    print(f"CC pool key {key_tuple(cc_key)} id {cc_id}")
    if a.cc_pool_id and a.cc_pool_id.lower() != cc_id.lower():
        raise RpcError(f"--cc-pool-id {a.cc_pool_id} is not the id of the CC pool key {cc_id}")
    if not chain.pool_initialized(cc_key):
        raise RpcError("the CC pool is not initialized at this block")
    total = chain.total_supply(a.cc)
    in_pool = chain.balance_of(a.cc, POOL_MANAGER)
    circulating = total - in_pool
    print(f"CC total supply {fmt(total)}, pool manager holds {fmt(in_pool)}, circulating {fmt(circulating)}")
    gas_price = parse_amount(a.gas_price_gwei, 9) if a.gas_price_gwei else chain.gas_price()
    gas_wei = a.gas_units * gas_price
    print(f"gas: {a.gas_units} units at {fmt(gas_price, 9, 3)} gwei = {fmt(gas_wei)} ETH per round trip")

    balance_key = None
    if a.balance_token:
        if not chain.has_code(a.balance_token):
            raise RpcError(f"the BALANCE token {a.balance_token} has no code at block {chain.block}")
        balance_key = pool_key(ZERO_ADDRESS, a.balance_token, a.balance_pool_fee, a.balance_pool_tick_spacing, a.balance_pool_hook)
        initialized = chain.pool_initialized(balance_key)
        print(f"BALANCE pool key {key_tuple(balance_key)} initialized {initialized}")
        if not initialized:
            balance_key = None
    else:
        print("no --balance-token given: the sale leg is reported as pool not initialized")

    def quote_buy(x):
        # ETH in (currency0) for exact CC out (currency1): zeroForOne
        return chain.quote_exact_output(cc_key, True, x)

    def quote_sell(y):
        if balance_key is None:
            return None
        # BALANCE in (currency1) for ETH out (currency0): not zeroForOne
        return chain.quote_exact_input(balance_key, False, y)

    rows = compute_rows(candidates, sizes, total, quote_buy, quote_sell, gas_wei, a.slippage_stress_bps, a.thin_impact_bps)
    print_rows(rows)
    print_backing(candidates, total, circulating, budget, minimum_working)
    eligible, chosen, arbitrage = recommend(candidates, rows, budget, max_allocation, backing_target, a.backing_basis,
                                            total, circulating, a.target_margin_bps)
    print(f"eligible candidates (within budget and maximum allocation): {', '.join(fmt(c) for c in eligible) or 'none'}")
    if backing_target is None:
        print("no --backing-target given: no reserve is recommended")
    elif chosen is None:
        print(f"no eligible candidate meets the backing target {fmt(backing_target)} BALANCE per CC on the {a.backing_basis} supply")
    else:
        print(f"recommended C = {fmt(chosen)} BALANCE: the smallest eligible candidate meeting {fmt(backing_target)} BALANCE per CC on the {a.backing_basis} supply")
    by_margin = margin_recommendation(rows, eligible, a.decision_size_bps, a.target_margin_bps)
    if by_margin is None:
        print(f"reserve needed for a {a.target_margin_bps} bps executable arbitrage margin at {a.decision_size_bps} bps of supply: none within budget (or the sale leg is unavailable)")
    else:
        print(f"reserve needed for a {a.target_margin_bps} bps executable arbitrage margin at {a.decision_size_bps} bps of supply: C = {fmt(by_margin)} BALANCE")
    print(arbitrage_sentence(arbitrage))
    print("the redeemable share is always on the total supply; the circulating column is informational and not an entitlement")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RpcError, QuoteRevert, ValueError) as e:
        print(f"calibrate: {e}", file=sys.stderr)
        sys.exit(2)
