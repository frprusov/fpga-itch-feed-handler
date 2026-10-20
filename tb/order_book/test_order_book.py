"""cocotb tests for rtl/order_book.vhd against the Python reference model.

Run from tb/order_book:   make
Run one test:             make COCOTB_TEST_FILTER=test_scenario_7_2
With waveforms:           make WAVES=1 COCOTB_TEST_FILTER=test_scenario_7_2

How it works:
  1. Build a list of messages and turn them into parser output with
     model.itch.parse_stream(encode_stream(...)), exactly what itch_parser delivers.
  2. Drive each ParsedMsg onto the in_* ports with a one-cycle in_valid pulse.
     Fields that are don't-care for the message type get RANDOM values, so the
     design must really ignore them.
  3. Wait until busy = '0' and record any bbo_valid / err_ref pulse.
  4. Compare with model.order_book.OrderBook(max_levels=32).apply() for that message.

Timing convention: inputs are driven and outputs sampled on the FALLING edge.
"""

import random
from collections import defaultdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from model.itch import (
    SIDE_BUY,
    SIDE_SELL,
    AddOrder,
    OrderCancel,
    OrderDelete,
    OrderExecuted,
    OrderReplace,
    ParsedMsg,
    encode_stream,
    parse_stream,
)
from model.order_book import BBO, OrderBook
from model.scenarios import SCENARIO_7_2, SCENARIO_7_2_EXPECTED
from model.stream_gen import random_stream

MAX_LEVELS = 32  # must match the generic of order_book.vhd
MAX_CYCLES = 20  # a message must be finished within this many cycles

# Maximum latency per message type in cycles (rising edges from in_valid to bbo_valid).
LATENCY_LIMIT = {"A": 3, "E": 4, "X": 4, "D": 4, "U": 6}


# --- helpers -------------------------------------------------------------------


async def setup(dut):
    """Start the clock and reset the book (clears all orders and levels)."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


def read_bbo(dut) -> BBO:
    return BBO(
        bool(dut.bid_valid.value),
        dut.bid_price.value.to_unsigned(),
        dut.bid_qty.value.to_unsigned(),
        bool(dut.ask_valid.value),
        dut.ask_price.value.to_unsigned(),
        dut.ask_qty.value.to_unsigned(),
    )


async def send(dut, m: ParsedMsg, rng: random.Random):
    """Apply one message. Returns (list of (cycle, BBO) pulses, list of err cycles)."""
    assert dut.busy.value == 0, "in_valid while the order book is busy"

    def or_random(value, bits):
        return value if value is not None else rng.getrandbits(bits)

    dut.in_type.value = ord(m.msg_type)
    dut.in_locate.value = m.locate
    dut.in_ref.value = m.ref
    dut.in_new_ref.value = or_random(m.new_ref, 64)
    dut.in_side.value = or_random(m.side, 1)
    dut.in_shares.value = or_random(m.shares, 32)
    dut.in_price.value = or_random(m.price, 32)
    dut.in_valid.value = 1

    bbos, errs = [], []
    for cycle in range(1, MAX_CYCLES + 1):
        await FallingEdge(dut.clk)
        if cycle == 1:
            dut.in_valid.value = 0
        if dut.bbo_valid.value == 1:
            bbos.append((cycle, read_bbo(dut)))
        if dut.err_ref.value == 1:
            errs.append(cycle)
        if dut.busy.value == 0:
            return bbos, errs
    raise AssertionError(f"order book still busy {MAX_CYCLES} cycles after {m}")


async def run_and_check(dut, msgs, seed=0, gaps=True, latencies=None):
    """Feed messages through model and DUT, compare after every message."""
    rng = random.Random(seed)
    parsed = parse_stream(encode_stream(msgs)).msgs
    book = OrderBook(max_levels=MAX_LEVELS)
    results = []
    for n, m in enumerate(parsed):
        expected = book.apply(m)
        bbos, errs = await send(dut, m, rng)

        where = f"message {n} ({m.msg_type} ref={m.ref})"
        if expected.bbo is None:
            assert not bbos, f"{where}: expected no bbo_valid, got {bbos}"
        else:
            assert len(bbos) == 1, f"{where}: expected one bbo_valid pulse, got {len(bbos)}"
            cycle, got = bbos[0]
            assert got == expected.bbo, f"{where}:\n  expected {expected.bbo}\n  got      {got}"
            if latencies is not None:
                latencies[m.msg_type].append(cycle)
        assert bool(errs) == expected.err, f"{where}: expected err_ref={expected.err}, got pulses {errs}"
        assert len(errs) <= 1, f"{where}: more than one err_ref pulse"
        results.append(expected)

        if gaps:
            for _ in range(rng.randint(0, 3)):
                await FallingEdge(dut.clk)
    return results


# --- tests -------------------------------------------------------------------------


@cocotb.test()
async def test_scenario_7_2(dut):
    """SPEC 7.2: all five message types, top of book after every message."""
    await setup(dut)
    results = await run_and_check(dut, SCENARIO_7_2)
    assert [r.bbo for r in results] == SCENARIO_7_2_EXPECTED


@cocotb.test()
async def test_other_locate_is_ignored(dut):
    """Messages for another stock_locate: no output, no error, book unchanged."""
    await setup(dut)
    await run_and_check(
        dut,
        [
            AddOrder(1, SIDE_BUY, 100, 1_000_000, locate=2),
            AddOrder(1, SIDE_BUY, 50, 999_900),
            OrderDelete(1, locate=2),
            OrderExecuted(1, 10),
        ],
    )


@cocotb.test()
async def test_same_price_aggregates(dut):
    """Orders at the same price add up in one level; replace inherits the side."""
    await setup(dut)
    await run_and_check(
        dut,
        [
            AddOrder(1, SIDE_BUY, 100, 1_000_000),
            AddOrder(2, SIDE_BUY, 50, 1_000_000),
            AddOrder(3, SIDE_SELL, 70, 1_000_500),
            OrderReplace(3, 4, 40, 1_000_400),
            OrderCancel(1, 100),
            OrderExecuted(2, 50),
        ],
    )


@cocotb.test()
async def test_invalid_feed(dut):
    """SPEC 5.4: invalid messages are ignored with an err_ref pulse."""
    await setup(dut)
    cases = [
        [OrderExecuted(5, 10)],  # unknown ref
        [OrderDelete(5)],  # unknown ref
        [OrderReplace(5, 6, 1, 1)],  # unknown ref
        [AddOrder(1024, SIDE_BUY, 1, 1)],  # ref out of range
        [AddOrder(2**64 - 1, SIDE_BUY, 1, 1)],  # ref out of range, high bits
        [AddOrder(1, SIDE_BUY, 1, 1), AddOrder(1, SIDE_BUY, 1, 1)],  # duplicate ref
        [AddOrder(1, SIDE_BUY, 1, 1), AddOrder(2, SIDE_BUY, 1, 1), OrderReplace(1, 2, 1, 1)],  # new_ref live
        [AddOrder(1, SIDE_BUY, 1, 1), OrderReplace(1, 5000, 1, 1)],  # new_ref out of range
    ]
    for case in cases:
        await reset(dut)
        await run_and_check(dut, case)


@cocotb.test()
async def test_overfill_saturates(dut):
    """E/X for more shares than left: order removed, bbo_valid AND err_ref."""
    await setup(dut)
    await run_and_check(
        dut,
        [AddOrder(1, SIDE_BUY, 100, 1_000_000), AddOrder(2, SIDE_BUY, 10, 999_000), OrderCancel(1, 150)],
    )


@cocotb.test()
async def test_replace_same_ref(dut):
    """U with new_ref == original ref is allowed."""
    await setup(dut)
    await run_and_check(dut, [AddOrder(7, SIDE_SELL, 100, 2_000_000), OrderReplace(7, 7, 60, 1_999_000)])


@cocotb.test()
async def test_level_overflow(dut):
    """SPEC 5.4: a new level on a full side is rejected; existing levels still work."""
    await setup(dut)
    full = [AddOrder(i, SIDE_BUY, 10, 1_000_000 - 100 * i) for i in range(MAX_LEVELS)]
    msgs = full + [
        AddOrder(100, SIDE_BUY, 10, 500_000),  # 33rd level: rejected
        AddOrder(101, SIDE_BUY, 10, 1_000_000),  # existing level: fine
        AddOrder(102, SIDE_SELL, 10, 1_100_000),  # other side: fine
        OrderDelete(5),  # frees a level
        AddOrder(103, SIDE_BUY, 10, 500_000),  # now fits, at the bottom
        OrderReplace(101, 104, 10, 400_000),  # level 1_000_000 keeps order 0: no room
    ]
    results = await run_and_check(dut, msgs, gaps=False)
    errs = [n for n, r in enumerate(results) if r.err]
    assert errs == [MAX_LEVELS, MAX_LEVELS + 5], f"unexpected error positions {errs}"


@cocotb.test()
async def test_reset_clears_book(dut):
    """After reset the book is empty again."""
    await setup(dut)
    await run_and_check(dut, [AddOrder(1, SIDE_BUY, 100, 1_000_000), AddOrder(2, SIDE_SELL, 100, 1_000_100)])
    await reset(dut)
    await run_and_check(dut, [AddOrder(1, SIDE_BUY, 5, 900_000)])  # ref 1 is free again, old levels gone


@cocotb.test()
async def test_random_streams(dut):
    """3 x 3000 random valid messages, each checked against the model."""
    await setup(dut)
    for seed in range(3):
        await reset(dut)
        await run_and_check(dut, random_stream(3000, seed=seed), seed=seed)


@cocotb.test()
async def test_latency(dut):
    """Order book latency per message type (SPEC 6)."""
    await setup(dut)
    latencies = defaultdict(list)
    await run_and_check(dut, SCENARIO_7_2, latencies=latencies)
    await reset(dut)
    await run_and_check(dut, random_stream(1000, seed=7), seed=7, latencies=latencies)
    for t in "AEXDU":
        worst = max(latencies[t])
        dut._log.info(f"{t}: bbo_valid {worst} cycle(s) after in_valid (worst of {len(latencies[t])})")
        assert worst <= LATENCY_LIMIT[t], f"{t}: latency {worst} > {LATENCY_LIMIT[t]}"
