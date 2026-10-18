"""Reference order book (SPEC 5).

Takes the parser output (ParsedMsg) one message at a time and returns the
top of book after every applied message.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from .itch import ParsedMsg, SIDE_BUY, SIDE_SELL


@dataclass(frozen=True)
class BBO:
    """Top of book, as on the VHDL outputs when bbo_valid = '1' (SPEC 5.5)."""

    bid_valid: bool
    bid_price: int
    bid_qty: int
    ask_valid: bool
    ask_price: int
    ask_qty: int

    def __str__(self) -> str:
        bid = f"{self.bid_price / 10_000:.4f} x {self.bid_qty}" if self.bid_valid else "-"
        ask = f"{self.ask_price / 10_000:.4f} x {self.ask_qty}" if self.ask_valid else "-"
        return f"bid {bid:>20} | ask {ask:>20}"


@dataclass(frozen=True)
class ApplyResult:
    bbo: BBO | None  # None: message not applied, so no bbo_valid pulse
    err: bool  # err_ref pulse (SPEC 5.4)


@dataclass
class _Order:
    side: int
    price: int
    shares: int


class OrderBook:
    def __init__(self, locate: int = 1, order_ref_bits: int = 10) -> None:
        self.locate = locate
        self.max_refs = 2**order_ref_bits
        self.orders: dict[int, _Order] = {}
        # levels[side][price] = total remaining shares at that price
        self.levels: dict[int, dict[int, int]] = {
            SIDE_BUY: defaultdict(int),
            SIDE_SELL: defaultdict(int),
        }

    # --- queries ---------------------------------------------------------------

    def bbo(self) -> BBO:
        bids = self.levels[SIDE_BUY]
        asks = self.levels[SIDE_SELL]
        if bids:
            bp = max(bids)
            bid = (True, bp, bids[bp])
        else:
            bid = (False, 0, 0)
        if asks:
            ap = min(asks)
            ask = (True, ap, asks[ap])
        else:
            ask = (False, 0, 0)
        return BBO(*bid, *ask)

    def _valid_ref(self, ref: int) -> bool:
        return 0 <= ref < self.max_refs

    def _live(self, ref: int) -> bool:
        return ref in self.orders

    # --- mutations (only called after validation) ------------------------------

    def _insert(self, ref: int, side: int, price: int, shares: int) -> None:
        self.orders[ref] = _Order(side, price, shares)
        self.levels[side][price] += shares

    def _reduce(self, ref: int, amount: int) -> None:
        order = self.orders[ref]
        amount = min(amount, order.shares)
        order.shares -= amount
        level = self.levels[order.side]
        level[order.price] -= amount
        if level[order.price] == 0:
            del level[order.price]
        if order.shares == 0:
            del self.orders[ref]

    def _remove(self, ref: int) -> None:
        self._reduce(ref, self.orders[ref].shares)

    # --- main entry point --------------------------------------------------------

    def apply(self, m: ParsedMsg) -> ApplyResult:
        if m.locate != self.locate:
            return ApplyResult(None, False)  # other instrument: ignore silently

        ignore = ApplyResult(None, True)  # invalid feed: book unchanged, err_ref

        if not self._valid_ref(m.ref):
            return ignore

        match m.msg_type:
            case "A":
                if self._live(m.ref):
                    return ignore
                self._insert(m.ref, m.side, m.price, m.shares)
                return ApplyResult(self.bbo(), False)

            case "E" | "X":
                if not self._live(m.ref):
                    return ignore
                overfill = m.shares > self.orders[m.ref].shares
                self._reduce(m.ref, m.shares)
                return ApplyResult(self.bbo(), overfill)

            case "D":
                if not self._live(m.ref):
                    return ignore
                self._remove(m.ref)
                return ApplyResult(self.bbo(), False)

            case "U":
                if not self._live(m.ref) or not self._valid_ref(m.new_ref):
                    return ignore
                if m.new_ref != m.ref and self._live(m.new_ref):
                    return ignore
                side = self.orders[m.ref].side  # inherited from the original order
                self._remove(m.ref)
                self._insert(m.new_ref, side, m.price, m.shares)
                return ApplyResult(self.bbo(), False)

        raise ValueError(f"unsupported message type {m.msg_type!r}")

    # --- self-check, used by tests ------------------------------------------------

    def check_invariants(self) -> None:
        """Levels must equal the sum of the live orders. Raises AssertionError if not."""
        expected: dict[int, dict[int, int]] = {SIDE_BUY: defaultdict(int), SIDE_SELL: defaultdict(int)}
        for o in self.orders.values():
            assert o.shares > 0, "order with 0 shares should have been removed"
            expected[o.side][o.price] += o.shares
        for side in (SIDE_BUY, SIDE_SELL):
            assert dict(self.levels[side]) == dict(expected[side]), f"level mismatch on side {side}"
