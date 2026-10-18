"""ITCH 5.0 subset: message definitions, encoder and reference parser.

Implements SPEC.md sections 2-4. This is the *reference* model: it is written
to be obviously correct, not to resemble the hardware. It parses with slices
on a complete byte string instead of a byte-by-byte state machine, so a bug in
the VHDL state machine cannot be copied into the model by accident.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

# --- Message types and lengths (SPEC 3) -------------------------------------

ADD = "A"
EXECUTED = "E"
CANCEL = "X"
DELETE = "D"
REPLACE = "U"

MSG_LEN = {ADD: 36, EXECUTED: 31, CANCEL: 23, DELETE: 19, REPLACE: 35}

SIDE_BUY = 0
SIDE_SELL = 1
_SIDE_TO_BYTE = {SIDE_BUY: b"B", SIDE_SELL: b"S"}
_BYTE_TO_SIDE = {ord("B"): SIDE_BUY, ord("S"): SIDE_SELL}


# --- Messages as the exchange sends them -------------------------------------


@dataclass(frozen=True)
class AddOrder:
    order_ref: int
    side: int  # SIDE_BUY or SIDE_SELL
    shares: int
    price: int  # 4 implied decimals: 1892500 = 189.2500
    locate: int = 1
    timestamp: int = 0
    tracking: int = 0
    stock: bytes = b"AAPL    "


@dataclass(frozen=True)
class OrderExecuted:
    order_ref: int
    executed_shares: int
    match_number: int = 0
    locate: int = 1
    timestamp: int = 0
    tracking: int = 0


@dataclass(frozen=True)
class OrderCancel:
    order_ref: int
    cancelled_shares: int
    locate: int = 1
    timestamp: int = 0
    tracking: int = 0


@dataclass(frozen=True)
class OrderDelete:
    order_ref: int
    locate: int = 1
    timestamp: int = 0
    tracking: int = 0


@dataclass(frozen=True)
class OrderReplace:
    original_order_ref: int
    new_order_ref: int
    shares: int
    price: int
    locate: int = 1
    timestamp: int = 0
    tracking: int = 0


@dataclass(frozen=True)
class RawMessage:
    """Any message body, sent as-is. Used to test unsupported types and bad lengths."""

    body: bytes


Message = AddOrder | OrderExecuted | OrderCancel | OrderDelete | OrderReplace | RawMessage


# --- Encoder ------------------------------------------------------------------


def _header(msg_type: str, locate: int, tracking: int, timestamp: int) -> bytes:
    return (
        msg_type.encode("ascii")
        + struct.pack(">HH", locate, tracking)
        + timestamp.to_bytes(6, "big")
    )


def encode_body(msg: Message) -> bytes:
    """Encode one message without length prefix."""
    match msg:
        case AddOrder():
            if len(msg.stock) != 8:
                raise ValueError("stock must be exactly 8 bytes")
            return (
                _header(ADD, msg.locate, msg.tracking, msg.timestamp)
                + struct.pack(">Q", msg.order_ref)
                + _SIDE_TO_BYTE[msg.side]
                + struct.pack(">I", msg.shares)
                + msg.stock
                + struct.pack(">I", msg.price)
            )
        case OrderExecuted():
            return _header(EXECUTED, msg.locate, msg.tracking, msg.timestamp) + struct.pack(
                ">QIQ", msg.order_ref, msg.executed_shares, msg.match_number
            )
        case OrderCancel():
            return _header(CANCEL, msg.locate, msg.tracking, msg.timestamp) + struct.pack(
                ">QI", msg.order_ref, msg.cancelled_shares
            )
        case OrderDelete():
            return _header(DELETE, msg.locate, msg.tracking, msg.timestamp) + struct.pack(
                ">Q", msg.order_ref
            )
        case OrderReplace():
            return _header(REPLACE, msg.locate, msg.tracking, msg.timestamp) + struct.pack(
                ">QQII", msg.original_order_ref, msg.new_order_ref, msg.shares, msg.price
            )
        case RawMessage():
            return msg.body
    raise TypeError(f"unknown message {msg!r}")


def frame(body: bytes) -> bytes:
    """Prepend the 2-byte big-endian length prefix (SPEC 2.1)."""
    if len(body) > 0xFFFF:
        raise ValueError("message too long for a 2-byte length prefix")
    return struct.pack(">H", len(body)) + body


def encode_stream(msgs: list[Message]) -> bytes:
    return b"".join(frame(encode_body(m)) for m in msgs)


# --- Reference parser (SPEC 4) -------------------------------------------------


@dataclass(frozen=True)
class ParsedMsg:
    """What the VHDL parser outputs when msg_valid = '1'.

    Fields that are don't-care for a message type (SPEC 4) are None.
    """

    msg_type: str
    locate: int
    timestamp: int
    ref: int
    new_ref: int | None = None
    side: int | None = None
    shares: int | None = None
    price: int | None = None


@dataclass(frozen=True)
class ParseResult:
    msgs: list[ParsedMsg]
    len_errors: int  # number of err_len pulses (SPEC 3.7)


def _decode(body: bytes) -> ParsedMsg:
    msg_type = chr(body[0])
    locate, _tracking = struct.unpack_from(">HH", body, 1)
    timestamp = int.from_bytes(body[5:11], "big")
    (ref,) = struct.unpack_from(">Q", body, 11)

    match msg_type:
        case "A":
            side = _BYTE_TO_SIDE.get(body[19])
            if side is None:
                raise ValueError(f"invalid side byte {body[19]:#04x}")
            (shares,) = struct.unpack_from(">I", body, 20)
            (price,) = struct.unpack_from(">I", body, 32)
            return ParsedMsg(msg_type, locate, timestamp, ref, side=side, shares=shares, price=price)
        case "E" | "X":
            (shares,) = struct.unpack_from(">I", body, 19)
            return ParsedMsg(msg_type, locate, timestamp, ref, shares=shares)
        case "D":
            return ParsedMsg(msg_type, locate, timestamp, ref)
        case "U":
            new_ref, shares, price = struct.unpack_from(">QII", body, 19)
            return ParsedMsg(msg_type, locate, timestamp, ref, new_ref=new_ref, shares=shares, price=price)
    raise AssertionError("unreachable")


def parse_stream(data: bytes) -> ParseResult:
    """Split a byte stream into messages and decode the supported ones.

    - Unsupported types are skipped silently.
    - Supported types with a wrong length are skipped and counted as len_errors.
    - An incomplete message at the end of the stream is ignored.
    """
    msgs: list[ParsedMsg] = []
    len_errors = 0
    pos = 0
    while pos + 2 <= len(data):
        (length,) = struct.unpack_from(">H", data, pos)
        pos += 2
        if pos + length > len(data):
            break  # incomplete message at end of stream
        body = data[pos : pos + length]
        pos += length

        if length == 0:
            continue
        msg_type = chr(body[0])
        if msg_type not in MSG_LEN:
            continue
        if length != MSG_LEN[msg_type]:
            len_errors += 1
            continue
        msgs.append(_decode(body))
    return ParseResult(msgs, len_errors)
