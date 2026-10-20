# SPEC — FPGA ITCH Feed Handler

Version: v1 (8-bit datapath), order book v5
Status: implemented. This document defines the behaviour that the Python reference model and the VHDL implementation must both satisfy; the testbenches check the VHDL against the model.

---

## 1. Overview

The design receives a byte stream of market-data messages, decodes them, and maintains a limit order book for one instrument. After every message that is applied to the book it outputs the current best bid and best ask (top of book).

```
  byte stream        ┌─────────────┐   decoded msg    ┌─────────────┐   best bid / ask
 ──────────────────▶ │ itch_parser │ ───────────────▶ │ order_book  │ ─────────────────▶
  AXI-Stream, 8 bit  └─────────────┘   (1 per msg)    └─────────────┘   (1 per applied msg)
```

The message layouts are byte-compatible with **Nasdaq TotalView-ITCH 5.0** for the subset of message types listed in section 3. This project implements only that subset and is not a complete ITCH implementation.

---

## 2. Input stream

### 2.1 Framing

Each message is preceded by a **2-byte big-endian length prefix**. The length counts only the message bytes that follow and does not include the prefix itself.

```
| len_hi | len_lo | msg[0] | msg[1] | ... | msg[len-1] | len_hi | len_lo | msg[0] | ...
```

- Messages follow each other directly, with no padding or separators.
- A length of 0 is legal and denotes an empty message; the parser simply continues with the next prefix.
- Messages of any type not listed in section 3 are **skipped** using the length prefix and produce no output.

### 2.2 Byte order and data types

| Type | Encoding |
|---|---|
| Integers | Unsigned, **big-endian** (most significant byte first) |
| Price | 32-bit unsigned integer with **4 implied decimals** (`1892500` = 189.2500) |
| Timestamp | 48-bit unsigned, nanoseconds since midnight |
| Alpha | ASCII, left-justified, padded with spaces (`0x20`) |

### 2.3 Interface (v1)

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst` | in | 1 | Synchronous reset, active high |
| `s_axis_tdata` | in | 8 | One byte of the stream |
| `s_axis_tvalid` | in | 1 | `s_axis_tdata` is valid this cycle |

- A byte is consumed on every rising clock edge where `s_axis_tvalid = '1'`.
- There is **no `tready`** (no backpressure). A network feed cannot be paused, so the design must accept one byte per cycle indefinitely.
- `s_axis_tvalid` may be low for any number of cycles between any two bytes, including in the middle of a message. Gaps must not change the result.

---

## 3. Supported messages

All supported messages start with the same 11-byte header. Offsets are relative to the first message byte (`msg[0]`), i.e. **after** the length prefix.

### 3.1 Common header

| Offset | Len | Field | Notes |
|---|---|---|---|
| 0 | 1 | `msg_type` | ASCII character |
| 1 | 2 | `stock_locate` | Instrument ID |
| 3 | 2 | `tracking_number` | Ignored |
| 5 | 6 | `timestamp` | ns since midnight |

### 3.2 `A` — Add Order (36 bytes)

| Offset | Len | Field |
|---|---|---|
| 0–10 | 11 | Common header (`msg_type = 'A'` = `0x41`) |
| 11 | 8 | `order_ref` |
| 19 | 1 | `side`: `'B'` (`0x42`) = buy, `'S'` (`0x53`) = sell |
| 20 | 4 | `shares` |
| 24 | 8 | `stock` (ignored; `stock_locate` identifies the instrument) |
| 32 | 4 | `price` |

### 3.3 `E` — Order Executed (31 bytes)

| Offset | Len | Field |
|---|---|---|
| 0–10 | 11 | Common header (`msg_type = 'E'` = `0x45`) |
| 11 | 8 | `order_ref` |
| 19 | 4 | `executed_shares` |
| 23 | 8 | `match_number` (ignored) |

### 3.4 `X` — Order Cancel (23 bytes)

| Offset | Len | Field |
|---|---|---|
| 0–10 | 11 | Common header (`msg_type = 'X'` = `0x58`) |
| 11 | 8 | `order_ref` |
| 19 | 4 | `cancelled_shares` |

### 3.5 `D` — Order Delete (19 bytes)

| Offset | Len | Field |
|---|---|---|
| 0–10 | 11 | Common header (`msg_type = 'D'` = `0x44`) |
| 11 | 8 | `order_ref` |

### 3.6 `U` — Order Replace (35 bytes)

| Offset | Len | Field |
|---|---|---|
| 0–10 | 11 | Common header (`msg_type = 'U'` = `0x55`) |
| 11 | 8 | `original_order_ref` |
| 19 | 8 | `new_order_ref` |
| 27 | 4 | `shares` |
| 31 | 4 | `price` |

### 3.7 Length check

If a message has a supported `msg_type` but its length prefix does not match the length in the table above, the message is skipped (no output) and `err_len` is pulsed for one cycle.

---

## 4. Parser output (`itch_parser`)

For every supported, correctly sized message the parser asserts `msg_valid` for exactly one cycle, together with the decoded fields.

| Signal | Width | A | E | X | D | U |
|---|---|---|---|---|---|---|
| `msg_valid` | 1 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `msg_type` | 8 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `msg_locate` | 16 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `msg_timestamp` | 48 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `msg_ref` | 64 | order_ref | order_ref | order_ref | order_ref | original_order_ref |
| `msg_new_ref` | 64 | – | – | – | – | new_order_ref |
| `msg_side` | 1 | `0` = buy, `1` = sell | – | – | – | – |
| `msg_shares` | 32 | shares | executed_shares | cancelled_shares | – | shares |
| `msg_price` | 32 | price | – | – | – | price |
| `err_len` | 1 | pulse on length mismatch (section 3.7) |

Fields marked `–` are don't-care: their value is undefined and the testbench does not check them.

The parser does **not** filter on `stock_locate`; it decodes every supported message. Filtering happens in the order book.

---

## 5. Order book (`order_book`)

### 5.1 Scope and parameters

| Generic | Default | Meaning |
|---|---|---|
| `LOCATE` | 1 | Only messages with `msg_locate = LOCATE` are applied; others are ignored |
| `ORDER_REF_BITS` | 10 | Order references must be `< 2**ORDER_REF_BITS` (1024) |
| `MAX_LEVELS` | 32 | Maximum number of distinct price levels per side |

The book tracks **one instrument**, at most **1024 live orders** (indexed directly by order reference) and at most **32 price levels per side**.

### 5.2 State

- **Order table**: for each live `order_ref`: `side`, `price`, `remaining_shares`.
- **Price levels**: for each side and each price with at least one live order: the sum of `remaining_shares` of all live orders at that price.

### 5.3 Rules

| Message | Effect |
|---|---|
| `A` | Insert order `order_ref` with `side`, `price`, `shares`. Add `shares` to the level (`side`, `price`). |
| `E` | Look up `order_ref`. Subtract `executed_shares` from the order and its level. |
| `X` | Look up `order_ref`. Subtract `cancelled_shares` from the order and its level. |
| `D` | Look up `order_ref`. Subtract its `remaining_shares` from its level and remove the order. |
| `U` | Remove `original_order_ref` as for `D`. Insert `new_order_ref` with the **side of the original order** and the new `shares` and `price`. |

Additional rules:

- An order whose `remaining_shares` reaches 0 is removed from the order table.
- A price level whose total reaches 0 is removed.
- **Best bid** = the highest price among buy levels. **Best ask** = the lowest price among sell levels. The quantity reported is the total of that level.

### 5.4 Invalid input

The feed is assumed to be consistent. The following cases indicate an invalid feed; the message is ignored (book unchanged, no `bbo_valid`) and `err_ref` is pulsed:

- `order_ref` or `new_order_ref` ≥ 2**`ORDER_REF_BITS`
- `E`, `X`, `D`, `U` referencing an order that is not live
- `A`, or the insert part of `U`, using an `order_ref` that is already live
- `A` with a price that is not yet a level on its side while that side already has `MAX_LEVELS` levels

If the insert part of a `U` needs a new level on a full side, the original order is still removed, the new order is **not** inserted, `bbo_valid` is asserted and `err_ref` is pulsed.

If `executed_shares` or `cancelled_shares` exceeds the remaining shares, the subtraction saturates at 0 (the order is removed) and `err_ref` is pulsed. The message still counts as applied.

### 5.5 Output

After every message that is applied to the book, `bbo_valid` is asserted for exactly one cycle with the top of book **after** applying that message.

| Signal | Width | Description |
|---|---|---|
| `bbo_valid` | 1 | New top of book available |
| `bid_valid` | 1 | `1` if at least one buy order is live |
| `bid_price` | 32 | Best bid price (0 if `bid_valid = 0`) |
| `bid_qty` | 32 | Total shares at best bid (0 if `bid_valid = 0`) |
| `ask_valid` | 1 | `1` if at least one sell order is live |
| `ask_price` | 32 | Best ask price (0 if `ask_valid = 0`) |
| `ask_qty` | 32 | Total shares at best ask (0 if `ask_valid = 0`) |
| `err_ref` | 1 | Pulse on invalid input (section 5.4) |
| `busy` | 1 | `1` while a message is being processed; `in_valid` must only be asserted when `busy = 0` |

The order book is busy for at most 7 cycles per message. The parser delivers at most one message every 21 cycles (shortest framed message), so `busy` never blocks the stream.

`bbo_valid` is asserted for every applied message, including messages that do not change the top of book. This keeps the comparison with the reference model one-to-one.

---

## 6. Latency and timing

Latencies are measured in clock cycles in simulation (cocotb, worst case over a random stream of 2000 messages) and converted to nanoseconds using the post-route clock period reported by Vivado.

| Metric | Definition | Measured |
|---|---|---|
| Parser latency | Rising edges from the edge that consumes the **last byte** of a message to the edge that sets `msg_valid` | 0 cycles (same edge) |
| Order book latency | Rising edges from the edge that sees `in_valid` to the edge that sets `bbo_valid` | `A` 3, `E`/`X`/`D` 4, `U` 6 cycles |
| End-to-end latency | Parser + order book | `A` 3, `E`/`X`/`D` 4, `U` 6 cycles |
| Clock frequency | Post-route, out of context, `xc7z020clg400-1` (PYNQ-Z2), Vivado 2024.1, default effort | **115.5 MHz** (8.656 ns) |
| End-to-end latency in ns | cycles × 8.656 ns | `A` 26.0 ns, `E`/`X`/`D` 34.6 ns, `U` 51.9 ns |

Resources (out of context): 17 642 LUTs (33 %), 7 018 flip-flops (7 %), 2 RAMB36 (1 %).

The original target was ≥ 200 MHz. It was not reached: comparing a price with 32 levels per side, deciding, and updating a sorted level array is a lot of logic per cycle on a 7-series `-1` device, and 70–80 % of the critical path is routing. The figure that matters is the **latency in nanoseconds**, not Fmax on its own: pipelining raised Fmax from 51 to 81 MHz but made the latency worse (see the version table in the README). A real 10G design runs at the MAC clock of 156.25 MHz (6.4 ns); reaching that is on the roadmap (section 9).

---

## 7. Reference test vector

### 7.1 First message, byte by byte

`A`: buy 100 @ 189.2500, `order_ref` 42, `stock_locate` 1, timestamp 09:30:00.000000000.

```
00 24                     length = 36
41                        'A'
00 01                     stock_locate = 1
00 00                     tracking_number
1F 1A CE D9 F0 00         timestamp = 34 200 000 000 000 ns
00 00 00 00 00 00 00 2A   order_ref = 42
42                        side = 'B'
00 00 00 64               shares = 100
41 41 50 4C 20 20 20 20   stock = "AAPL    "
00 1C E0 94               price = 1 892 500 -> 189.2500
```

### 7.2 Seven-message scenario

All messages use `stock_locate = 1`.

| # | Message | Best bid | Best ask |
|---|---|---|---|
| 1 | `A` ref 42, buy 100 @ 189.2500 | 189.2500 × 100 | – |
| 2 | `A` ref 43, buy 200 @ 189.3000 | 189.3000 × 200 | – |
| 3 | `A` ref 44, sell 150 @ 189.4000 | 189.3000 × 200 | 189.4000 × 150 |
| 4 | `E` ref 43, 30 executed | 189.3000 × 170 | 189.4000 × 150 |
| 5 | `X` ref 44, 50 cancelled | 189.3000 × 170 | 189.4000 × 100 |
| 6 | `U` ref 43 → 45, 300 @ 189.2600 | 189.2600 × 300 | 189.4000 × 100 |
| 7 | `D` ref 45 | 189.2500 × 100 | 189.4000 × 100 |

The Python reference model and the VHDL implementation must both reproduce this table exactly.

---

## 8. Simplifications compared to real ITCH 5.0

- Only message types `A`, `E`, `X`, `D`, `U` affect the book. Other types (including `F`, `C`, `P`, system and administrative messages) are skipped.
- One instrument per instance, selected by `stock_locate`.
- Order references are limited to 0–1023 so the order table can be directly indexed. Real feeds use 64-bit references and would need a hash table.
- Quantities are 32 bits; overflow of aggregated level quantities is not handled.
- No sequence numbers, packet loss detection or recovery (MoldUDP64 layer is out of scope).

---

## 9. Roadmap

- **v1**: 8-bit AXI-Stream input, one byte per cycle.
- **Order book at 156.25 MHz** (the 10G MAC clock): fewer price levels in registers (only the top N matter for the top of book), deeper levels in BRAM, and overlapping consecutive messages in the pipeline.
- **v2**: 64-bit AXI-Stream input (8 bytes per cycle, as delivered by a 10G Ethernet MAC at 156.25 MHz), with messages starting at arbitrary byte offsets within a word. Goal: reduce parser latency per message.
