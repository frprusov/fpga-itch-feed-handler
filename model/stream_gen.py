"""Random generator of *valid* ITCH streams, for stress testing model and VHDL.

Respects the SPEC constraints: order refs < 1024, E/X never exceed the remaining
shares, only live orders are referenced. Optionally mixes in messages for other
instruments and unsupported message types, which the design must ignore.

It does not enforce price-time priority (an E may hit an order that is not at
the top of book). That is fine: the order book only applies what the feed says.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

from .itch import (
    SIDE_BUY,
    SIDE_SELL,
    AddOrder,
    Message,
    OrderCancel,
    OrderDelete,
    OrderExecuted,
    OrderReplace,
    RawMessage,
)

MID_PRICE = 1_890_000  # 189.0000
TICK = 100  # 0.01


@dataclass
class _Live:
    side: int
    price: int
    shares: int


def random_stream(
    n: int,
    seed: int = 0,
    locate: int = 1,
    max_refs: int = 1024,
    noise: bool = True,
) -> list[Message]:
    rng = random.Random(seed)
    live: dict[int, _Live] = {}
    free = list(range(max_refs))
    rng.shuffle(free)
    msgs: list[Message] = []
    ts = 34_200_000_000_000  # 09:30:00

    def new_price(side: int) -> int:
        # Bids mostly below mid, asks mostly above, with some overlap-free spread.
        offset = rng.randint(1, 20) * TICK
        return MID_PRICE - offset if side == SIDE_BUY else MID_PRICE + offset

    while len(msgs) < n:
        ts += rng.randint(1, 5_000)

        if noise and rng.random() < 0.05:
            if rng.random() < 0.5:
                # Unsupported type 'S' (System Event, 12 bytes): must be skipped.
                body = b"S" + bytes(10) + b"O"
                msgs.append(RawMessage(body))
            else:
                # Valid Add Order for another instrument: must be ignored by the book.
                msgs.append(AddOrder(0, SIDE_BUY, 100, MID_PRICE, locate=locate + 1, timestamp=ts))
            continue

        actions = ["A"]
        if live:
            actions += ["E", "X", "D", "U"]
        weights = [5 if len(live) < max_refs // 2 else 1] + [1] * (len(actions) - 1)
        action = rng.choices(actions, weights)[0]
        if action == "A" and not free:
            action = "D"

        if action == "A":
            ref = free.pop()
            side = rng.choice((SIDE_BUY, SIDE_SELL))
            o = _Live(side, new_price(side), rng.randint(1, 50) * 100)
            live[ref] = o
            msgs.append(AddOrder(ref, side, o.shares, o.price, locate=locate, timestamp=ts))

        elif action in ("E", "X"):
            ref = rng.choice(list(live))
            o = live[ref]
            amount = rng.randint(1, o.shares)
            o.shares -= amount
            if o.shares == 0:
                del live[ref]
                free.append(ref)
            if action == "E":
                msgs.append(OrderExecuted(ref, amount, match_number=len(msgs), locate=locate, timestamp=ts))
            else:
                msgs.append(OrderCancel(ref, amount, locate=locate, timestamp=ts))

        elif action == "D":
            ref = rng.choice(list(live))
            del live[ref]
            free.append(ref)
            msgs.append(OrderDelete(ref, locate=locate, timestamp=ts))

        elif action == "U":
            ref = rng.choice(list(live))
            o = live.pop(ref)
            new_ref = free.pop(0) if free else ref  # a fresh ref, as real feeds do
            if new_ref != ref:
                free.append(ref)
            n_o = _Live(o.side, new_price(o.side), rng.randint(1, 50) * 100)
            live[new_ref] = n_o
            msgs.append(OrderReplace(ref, new_ref, n_o.shares, n_o.price, locate=locate, timestamp=ts))

    return msgs
