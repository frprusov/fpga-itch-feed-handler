"""cocotb tests for rtl/itch_parser.vhd against the Python reference model.

Run from tb/parser:   make
Run one test:         make COCOTB_TEST_FILTER=test_scenario_7_2

How it works:
  1. Build a list of messages, encode it with model.itch.encode_stream().
  2. A driver task feeds the bytes into s_axis_tdata, one per cycle,
     optionally with random gaps (s_axis_tvalid = '0').
  3. A monitor task records every msg_valid and err_len pulse.
  4. The recorded messages must equal model.itch.parse_stream() of the same bytes.

Timing convention (same as the counter test): inputs are driven and outputs
are sampled on the FALLING edge, so everything is stable.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from model.itch import (
    SIDE_BUY,
    AddOrder,
    OrderDelete,
    RawMessage,
    encode_body,
    encode_stream,
    frame,
    parse_stream,
)
from model.scenarios import ADD_ORDER_EXAMPLE, ADD_ORDER_EXAMPLE_BYTES, SCENARIO_7_2
from model.stream_gen import random_stream

# Fields of ParsedMsg and the DUT output that carries them.
FIELDS = {
    "msg_type": "msg_type",
    "locate": "msg_locate",
    "timestamp": "msg_timestamp",
    "ref": "msg_ref",
    "new_ref": "msg_new_ref",
    "side": "msg_side",
    "shares": "msg_shares",
    "price": "msg_price",
}


# --- helpers -------------------------------------------------------------------


def as_int(value) -> int:
    """std_logic_vector -> LogicArray (.to_unsigned()), std_logic -> Logic (int())."""
    return value.to_unsigned() if hasattr(value, "to_unsigned") else int(value)


async def setup(dut):
    """Start the clock and apply a synchronous reset for 2 cycles."""
    Clock(dut.clk, 10, unit="ns").start()
    dut.rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


class Monitor:
    """Records every msg_valid / err_len pulse, with the rising-edge number it came from."""

    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0  # number of rising edges since start of monitor
        self.msgs = []  # list of (cycle, dict of field values)
        self.len_errors = 0
        cocotb.start_soon(self._run())

    async def _run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            self.cycle += 1
            await FallingEdge(dut.clk)
            if dut.msg_valid.value == 1:
                got = {name: as_int(getattr(dut, sig).value) for name, sig in FIELDS.items()}
                got["msg_type"] = chr(got["msg_type"])
                self.msgs.append((self.cycle, got))
            if dut.err_len.value == 1:
                self.len_errors += 1


async def drive(dut, data: bytes, gap_prob: float = 0.0, seed: int = 0, monitor=None):
    """Feed `data` into the parser, one byte per cycle, with random tvalid gaps.

    Returns the list of rising-edge numbers at which each byte was consumed
    (only if a monitor is given, otherwise an empty list).
    """
    rng = random.Random(seed)
    consumed_at = []
    for byte in data:
        while rng.random() < gap_prob:
            dut.s_axis_tvalid.value = 0
            await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = byte
        dut.s_axis_tvalid.value = 1
        if monitor is not None:
            consumed_at.append(monitor.cycle + 1)  # consumed by the next rising edge
        await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    await ClockCycles(dut.clk, 3)  # let the last pulse come out
    await FallingEdge(dut.clk)
    return consumed_at


def check(expected_msgs, got_msgs):
    """Compare parser output with the model. Only fields that are not None are checked."""
    got = [g for _, g in got_msgs]
    assert len(got) == len(expected_msgs), f"expected {len(expected_msgs)} messages, got {len(got)}"
    for n, (e, g) in enumerate(zip(expected_msgs, got)):
        for field in FIELDS:
            want = getattr(e, field)
            if want is None:
                continue  # don't care (SPEC 4)
            assert g[field] == want, (
                f"message {n} ({e.msg_type}), field {field}: expected {want}, got {g[field]}"
            )


async def run_stream(dut, msgs, gap_prob=0.0, seed=0):
    await setup(dut)
    mon = Monitor(dut)
    data = encode_stream(msgs)
    await drive(dut, data, gap_prob=gap_prob, seed=seed)
    expected = parse_stream(data)
    check(expected.msgs, mon.msgs)
    assert mon.len_errors == expected.len_errors, (
        f"expected {expected.len_errors} err_len pulses, got {mon.len_errors}"
    )
    return mon


# --- tests -------------------------------------------------------------------------


@cocotb.test()
async def test_spec_example(dut):
    """SPEC 7.1: the single Add Order, byte by byte."""
    assert encode_stream([ADD_ORDER_EXAMPLE]) == ADD_ORDER_EXAMPLE_BYTES
    await run_stream(dut, [ADD_ORDER_EXAMPLE])


@cocotb.test()
async def test_scenario_7_2(dut):
    """SPEC 7.2: all five message types, back to back."""
    await run_stream(dut, SCENARIO_7_2)


@cocotb.test()
async def test_scenario_with_gaps(dut):
    """Same scenario with random tvalid gaps, also in the middle of messages (SPEC 2.3)."""
    await run_stream(dut, SCENARIO_7_2, gap_prob=0.3, seed=1)


@cocotb.test()
async def test_skip_unknown_type(dut):
    """Unsupported types and empty messages are skipped without output (SPEC 2.1)."""
    msgs = [
        RawMessage(b"S" + bytes(10) + b"O"),  # System Event, 12 bytes
        RawMessage(b""),  # length 0
        ADD_ORDER_EXAMPLE,
        RawMessage(b"R" + bytes(38)),  # Stock Directory, 39 bytes
        OrderDelete(42),
    ]
    await run_stream(dut, msgs)


@cocotb.test()
async def test_wrong_length(dut):
    """Supported type with a wrong length: no msg_valid, one err_len, parser stays in sync (SPEC 3.7)."""
    too_long = encode_body(ADD_ORDER_EXAMPLE) + b"\x00"  # 37 bytes
    too_short = encode_body(OrderDelete(1))[:-1]  # 18 bytes
    msgs = [RawMessage(too_long), OrderDelete(42), RawMessage(too_short), ADD_ORDER_EXAMPLE]
    await run_stream(dut, msgs)


@cocotb.test()
async def test_sell_side(dut):
    """Side byte 'S' must give msg_side = '1'."""
    await run_stream(dut, [AddOrder(7, 1, 500, 1_000_000), AddOrder(8, SIDE_BUY, 1, 1)])


@cocotb.test()
async def test_random_stream(dut):
    """2000 random valid messages, with noise and gaps."""
    await run_stream(dut, random_stream(2000, seed=42), gap_prob=0.1, seed=42)


@cocotb.test()
async def test_latency(dut):
    """Parser latency (SPEC 6): rising edges between consuming the last byte and msg_valid."""
    await setup(dut)
    mon = Monitor(dut)
    msgs = SCENARIO_7_2
    frames = [frame(encode_body(m)) for m in msgs]
    consumed = await drive(dut, b"".join(frames), monitor=mon)

    # Index of the last byte of each frame in the stream.
    last_byte_idx, pos = [], 0
    for f in frames:
        pos += len(f)
        last_byte_idx.append(pos - 1)

    assert len(mon.msgs) == len(msgs)
    latencies = []
    for (valid_cycle, got), idx in zip(mon.msgs, last_byte_idx):
        lat = valid_cycle - consumed[idx]
        latencies.append(lat)
        dut._log.info(f"{got['msg_type']}: msg_valid {lat} cycle(s) after the edge that consumed the last byte")
    assert max(latencies) <= 1, f"parser latency {max(latencies)} > SPEC target of 1 cycle"
