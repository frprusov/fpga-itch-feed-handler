"""End-to-end cocotb tests for rtl/feed_handler.vhd: bytes in, top of book out.

Run from tb/feed_handler:   make
Run one test:               make COCOTB_TEST_FILTER=test_scenario_7_2
With waveforms:             make WAVES=1 COCOTB_TEST_FILTER=test_scenario_7_2

The reference is the complete Python model:
    parse_stream(bytes)  ->  OrderBook(max_levels=32).apply() for every message
Every bbo_valid pulse of the hardware must equal the model's BBO, in the same
order, and the number of err_len / err_ref pulses must match.

Timing convention: inputs are driven and outputs sampled on the FALLING edge.
"""

import random
from collections import defaultdict
from dataclasses import dataclass

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from model.itch import (
    SIDE_BUY,
    SIDE_SELL,
    AddOrder,
    OrderDelete,
    OrderReplace,
    RawMessage,
    encode_body,
    frame,
    parse_stream,
)
from model.order_book import BBO, OrderBook
from model.scenarios import ADD_ORDER_EXAMPLE, SCENARIO_7_2, SCENARIO_7_2_EXPECTED
from model.stream_gen import random_stream

MAX_LEVELS = 32  # must match the generic of feed_handler.vhd

# End-to-end latency limit per message type (rising edges from the edge that
# consumes the last byte to the edge that sets bbo_valid). Parser 0 + book.
LATENCY_LIMIT = {"A": 3, "E": 4, "X": 4, "D": 4, "U": 6}


# --- helpers -------------------------------------------------------------------


def start_clock(dut):
    """Start the 100 MHz simulation clock. Call once per test."""
    Clock(dut.clk, 10, unit="ns").start()


async def reset(dut):
    """Synchronous reset: empties the order book and restarts the parser."""
    dut.rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
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


class Monitor:
    """Counts rising edges and records every output pulse with its edge number."""

    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.bbos = []  # list of (cycle, BBO)
        self.err_len = 0
        self.err_ref = 0
        self._task = cocotb.start_soon(self._run())

    def stop(self):
        self._task.cancel()

    async def _run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            self.cycle += 1
            await FallingEdge(dut.clk)
            if dut.bbo_valid.value == 1:
                self.bbos.append((self.cycle, read_bbo(dut)))
            if dut.err_len.value == 1:
                self.err_len += 1
            if dut.err_ref.value == 1:
                self.err_ref += 1


@dataclass
class Expected:
    """What the model predicts for one framed message."""

    msg_type: str
    last_byte: int  # index of the last byte of this frame in the stream
    bbo: BBO | None


def model(msgs):
    """Run the reference model per frame. Returns (bytes, list[Expected], err_len, err_ref)."""
    book = OrderBook(max_levels=MAX_LEVELS)
    data = b""
    expected, err_len, err_ref = [], 0, 0
    for m in msgs:
        f = frame(encode_body(m))
        data += f
        parsed = parse_stream(f)
        err_len += parsed.len_errors
        for p in parsed.msgs:  # 0 or 1 message per frame
            r = book.apply(p)
            err_ref += r.err
            expected.append(Expected(p.msg_type, len(data) - 1, r.bbo))
    return data, expected, err_len, err_ref


async def drive(dut, mon, data: bytes, gap_prob=0.0, seed=0):
    """Feed the bytes, one per cycle with random gaps. Returns the edge that consumed each byte."""
    rng = random.Random(seed)
    consumed_at = []
    for byte in data:
        while rng.random() < gap_prob:
            dut.s_axis_tvalid.value = 0
            await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = byte
        dut.s_axis_tvalid.value = 1
        consumed_at.append(mon.cycle + 1)
        await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    await ClockCycles(dut.clk, 8)  # let the last message through the book
    await FallingEdge(dut.clk)
    return consumed_at


async def run_and_check(dut, msgs, gap_prob=0.0, seed=0, latencies=None):
    """Reset, stream `msgs` through the DUT and compare every output with the model."""
    await reset(dut)
    mon = Monitor(dut)
    data, expected, err_len, err_ref = model(msgs)
    consumed_at = await drive(dut, mon, data, gap_prob, seed)
    mon.stop()

    want = [e for e in expected if e.bbo is not None]
    assert len(mon.bbos) == len(want), f"expected {len(want)} bbo_valid pulses, got {len(mon.bbos)}"
    for n, ((cycle, got), e) in enumerate(zip(mon.bbos, want)):
        assert got == e.bbo, f"bbo pulse {n} ({e.msg_type}):\n  expected {e.bbo}\n  got      {got}"
        lat = cycle - consumed_at[e.last_byte]
        assert lat <= LATENCY_LIMIT[e.msg_type], f"bbo pulse {n} ({e.msg_type}): latency {lat}"
        if latencies is not None:
            latencies[e.msg_type].append(lat)
    assert mon.err_len == err_len, f"expected {err_len} err_len pulses, got {mon.err_len}"
    assert mon.err_ref == err_ref, f"expected {err_ref} err_ref pulses, got {mon.err_ref}"
    return mon


# --- tests -------------------------------------------------------------------------


@cocotb.test()
async def test_scenario_7_2(dut):
    """SPEC 7.2 end to end: the bytes of the 7 messages in, the 7 BBOs of the table out."""
    start_clock(dut)
    mon = await run_and_check(dut, SCENARIO_7_2)
    assert [b for _, b in mon.bbos] == SCENARIO_7_2_EXPECTED


@cocotb.test()
async def test_scenario_with_gaps(dut):
    """Same scenario with random tvalid gaps, also inside messages."""
    start_clock(dut)
    await run_and_check(dut, SCENARIO_7_2, gap_prob=0.3, seed=1)


@cocotb.test()
async def test_mixed_errors(dut):
    """Unknown types, wrong lengths, unknown refs and another instrument in one stream."""
    start_clock(dut)
    msgs = [
        RawMessage(b"S" + bytes(10) + b"O"),  # unsupported type: skipped
        ADD_ORDER_EXAMPLE,  # ref 42
        RawMessage(encode_body(ADD_ORDER_EXAMPLE) + b"\x00"),  # wrong length: err_len
        OrderDelete(99),  # unknown ref: err_ref
        AddOrder(1, SIDE_SELL, 50, 1_900_000, locate=2),  # other instrument: ignored
        AddOrder(43, SIDE_SELL, 50, 1_900_000),
        OrderReplace(43, 42, 10, 1_899_000),  # new ref 42 is live: err_ref
        OrderDelete(42),
    ]
    await run_and_check(dut, msgs)


@cocotb.test()
async def test_level_overflow(dut):
    """A 33rd price level on one side is rejected (SPEC 5.4)."""
    start_clock(dut)
    msgs = [AddOrder(i, SIDE_BUY, 10, 1_000_000 - 100 * i) for i in range(MAX_LEVELS + 1)]
    msgs.append(OrderDelete(0))
    await run_and_check(dut, msgs)


@cocotb.test()
async def test_random_streams(dut):
    """3 x 3000 random messages with noise, at full rate and with gaps."""
    start_clock(dut)
    for seed, gaps in [(0, 0.0), (1, 0.1), (2, 0.3)]:
        await run_and_check(dut, random_stream(3000, seed=seed), gap_prob=gaps, seed=seed)


@cocotb.test()
async def test_latency(dut):
    """End-to-end latency per message type: last byte in -> bbo_valid out."""
    start_clock(dut)
    latencies = defaultdict(list)
    await run_and_check(dut, random_stream(2000, seed=11), latencies=latencies)
    for t in "AEXDU":
        lat = latencies[t]
        dut._log.info(
            f"{t}: {max(lat)} cycle(s) from last byte to bbo_valid "
            f"(worst of {len(lat)}; = {max(lat) * 5} ns at 200 MHz)"
        )
