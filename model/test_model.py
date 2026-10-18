"""Tests for the reference model. Run from the repo root:

    python -m pytest model -v
"""

import struct

import pytest

from model.itch import (
    MSG_LEN,
    SIDE_BUY,
    SIDE_SELL,
    AddOrder,
    OrderCancel,
    OrderDelete,
    OrderExecuted,
    OrderReplace,
    RawMessage,
    encode_body,
    encode_stream,
    frame,
    parse_stream,
)
from model.order_book import BBO, OrderBook
from model.scenarios import (
    ADD_ORDER_EXAMPLE,
    ADD_ORDER_EXAMPLE_BYTES,
    SCENARIO_7_2,
    SCENARIO_7_2_EXPECTED,
)
from model.stream_gen import random_stream


def run(msgs, book=None):
    """Encode, parse and apply. Returns (book, list of ApplyResult, ParseResult)."""
    book = book or OrderBook()
    parsed = parse_stream(encode_stream(msgs))
    results = [book.apply(m) for m in parsed.msgs]
    return book, results, parsed


# --- Encoder / parser -----------------------------------------------------------


def test_add_order_bytes_match_spec():
    assert frame(encode_body(ADD_ORDER_EXAMPLE)) == ADD_ORDER_EXAMPLE_BYTES


@pytest.mark.parametrize(
    "msg",
    [
        AddOrder(1, SIDE_BUY, 1, 1),
        OrderExecuted(1, 1),
        OrderCancel(1, 1),
        OrderDelete(1),
        OrderReplace(1, 2, 1, 1),
    ],
)
def test_message_lengths_match_spec(msg):
    body = encode_body(msg)
    assert len(body) == MSG_LEN[chr(body[0])]


def test_roundtrip_fields():
    msgs = [
        AddOrder(42, SIDE_SELL, 123, 4_567_890, locate=7, timestamp=999),
        OrderExecuted(42, 23, locate=7, timestamp=1000),
        OrderCancel(42, 50, locate=7),
        OrderReplace(42, 43, 77, 4_567_800, locate=7),
        OrderDelete(43, locate=7),
    ]
    p = parse_stream(encode_stream(msgs)).msgs
    assert [m.msg_type for m in p] == ["A", "E", "X", "U", "D"]
    assert (p[0].ref, p[0].side, p[0].shares, p[0].price, p[0].locate, p[0].timestamp) == (
        42, SIDE_SELL, 123, 4_567_890, 7, 999,
    )
    assert (p[1].ref, p[1].shares, p[1].timestamp) == (42, 23, 1000)
    assert (p[2].ref, p[2].shares) == (42, 50)
    assert (p[3].ref, p[3].new_ref, p[3].shares, p[3].price) == (42, 43, 77, 4_567_800)
    assert p[4].ref == 43


def test_unknown_type_is_skipped():
    msgs = [RawMessage(b"S" + bytes(10) + b"O"), ADD_ORDER_EXAMPLE, RawMessage(b"")]
    parsed = parse_stream(encode_stream(msgs))
    assert len(parsed.msgs) == 1
    assert parsed.msgs[0].ref == 42
    assert parsed.len_errors == 0


def test_wrong_length_is_skipped_and_flagged():
    bad = encode_body(ADD_ORDER_EXAMPLE) + b"\x00"  # 37 bytes for an 'A'
    msgs = [RawMessage(bad), OrderDelete(42)]
    parsed = parse_stream(encode_stream(msgs))
    assert parsed.len_errors == 1
    assert [m.msg_type for m in parsed.msgs] == ["D"]  # parser stays in sync


def test_incomplete_message_at_end_is_ignored():
    data = encode_stream([ADD_ORDER_EXAMPLE]) + struct.pack(">H", 36) + b"A"
    assert len(parse_stream(data).msgs) == 1


# --- Order book -----------------------------------------------------------------


def test_scenario_7_2():
    _, results, _ = run(SCENARIO_7_2)
    got = [r.bbo for r in results]
    for i, (g, e) in enumerate(zip(got, SCENARIO_7_2_EXPECTED, strict=True), start=1):
        assert g == e, f"message {i}: expected {e}, got {g}"
    assert not any(r.err for r in results)


def test_other_locate_is_ignored():
    book, results, _ = run([AddOrder(1, SIDE_BUY, 100, 1_000_000, locate=2)])
    assert results[0].bbo is None and not results[0].err
    assert book.bbo() == BBO(False, 0, 0, False, 0, 0)


def test_levels_aggregate_orders_at_same_price():
    _, results, _ = run([AddOrder(1, SIDE_BUY, 100, 1_000_000), AddOrder(2, SIDE_BUY, 50, 1_000_000)])
    assert results[-1].bbo.bid_qty == 150


def test_replace_inherits_side():
    _, results, _ = run([AddOrder(1, SIDE_SELL, 100, 2_000_000), OrderReplace(1, 2, 40, 1_990_000)])
    bbo = results[-1].bbo
    assert not bbo.bid_valid
    assert (bbo.ask_price, bbo.ask_qty) == (1_990_000, 40)


def test_execute_to_zero_removes_order():
    book, _, _ = run([AddOrder(1, SIDE_BUY, 100, 1_000_000), OrderExecuted(1, 100)])
    assert 1 not in book.orders
    assert not book.bbo().bid_valid


@pytest.mark.parametrize(
    "msgs",
    [
        [OrderExecuted(5, 10)],  # unknown ref
        [OrderDelete(5)],  # unknown ref
        [AddOrder(1024, SIDE_BUY, 1, 1)],  # ref out of range
        [AddOrder(1, SIDE_BUY, 1, 1), AddOrder(1, SIDE_BUY, 1, 1)],  # duplicate ref
        [AddOrder(1, SIDE_BUY, 1, 1), AddOrder(2, SIDE_BUY, 1, 1), OrderReplace(1, 2, 1, 1)],  # new_ref live
    ],
)
def test_invalid_feed_is_ignored_and_flagged(msgs):
    book, results, _ = run(msgs)
    for r in results[:-1]:
        assert r.bbo is not None  # setup messages are applied
    last = results[-1]
    assert last.bbo is None and last.err
    book.check_invariants()


def test_overfill_saturates_and_flags():
    book, results, _ = run([AddOrder(1, SIDE_BUY, 100, 1_000_000), OrderCancel(1, 150)])
    assert results[-1].err
    assert results[-1].bbo == BBO(False, 0, 0, False, 0, 0)
    assert 1 not in book.orders


# --- Stress test ------------------------------------------------------------------


@pytest.mark.parametrize("seed", range(5))
def test_random_stream_is_consistent(seed):
    msgs = random_stream(5_000, seed=seed)
    book, results, parsed = run(msgs)
    assert parsed.len_errors == 0
    assert not any(r.err for r in results), "generator should only produce valid feeds"
    book.check_invariants()
    for r in results:
        if r.bbo and r.bbo.bid_valid and r.bbo.ask_valid:
            assert r.bbo.bid_price < r.bbo.ask_price, "book should never be crossed"
