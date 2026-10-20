# FPGA ITCH 5.0 Feed Handler

A market-data feed handler in VHDL. A raw **Nasdaq ITCH 5.0** byte stream comes in. A **limit order book** for one instrument is kept up to date, and after every message the **best bid and best ask** come out.

The VHDL is verified message by message against a Python reference model, using cocotb and GHDL. Timing is measured post-route in Vivado for the Zynq-7020 on a PYNQ-Z2.

| | |
|---|---|
| Clock | **115.5 MHz** post-route on `xc7z020clg400-1` (out of context, Vivado 2024.1) |
| Latency, last byte in → top of book out | **A 26.0 ns** (3 cycles) · **E/X/D 34.6 ns** (4) · **U 51.9 ns** (6) |
| Resources | 17.6k LUTs (33 %), 7.0k FFs (7 %), 2 BRAM |
| Verification | 52 tests: Python model (28) + cocotb on GHDL (24), including 9 000 random messages compared one by one with the model |

The full specification is in [SPEC.md](SPEC.md).

---

## Architecture

```
                 ┌──────────────────────────── feed_handler ───────────────────────────┐
                 │                                                                      │
 s_axis_tdata ──►│  itch_parser            msg_valid, type,       order_book            │──► bbo_valid
 (8 bit, 1 B/clk)│  ─ length prefix FSM    ref, new_ref, side,    ─ live bits (1024 FF) │    bid price/qty
 s_axis_tvalid ─►│  ─ field shift regs     shares, price          ─ order table (BRAM)  │    ask price/qty
                 │  ─ 0-cycle latency  ──────────────────────────► ─ 2 × 32 sorted      │──► err_ref
                 │                     ──► err_len                   price levels       │
                 └──────────────────────────────────────────────────────────────────────┘
```

**`itch_parser`.** It reads one byte per clock: the 2-byte length prefix first, then the message body. Each field has its own shift register, and a byte goes into it when its offset falls inside that field. When the last byte arrives, all fields are already complete, so `msg_valid` rises on the **same clock edge** (0 cycles). Message types the book does not use are skipped using the length prefix. A wrong length for a supported type pulses `err_len`.

**`order_book`.** It is a 4-state FSM (`IDLE → DECIDE → FIND → APPLY`) with three kinds of storage:

- **`live`**: one flip-flop per order reference, so a reset empties the book in one cycle.
- **Order table**: a BRAM of 1024 × 65 bits holding side, price and remaining shares per order. `E`, `X`, `D` and `U` look up the stored order here.
- **Price levels**: 32 per side, kept in registers, **sorted best first**. The top of book is therefore always entry 0, with no search on the output side.

Each message turns into one or two *level operations*: add shares at a price, or subtract them.

- `FIND` compares the operation's price with all 64 levels in parallel and stores the results as bit vectors: which level matches, which levels are better, and whether the level becomes empty. In the same cycle it precomputes the new quantity for every level.
- `APPLY` then only has to select, using those bit vectors. It updates one level, inserts a level (shifting the worse levels down), or removes one (shifting them up).

A `U` (replace) is a remove followed by an insert, which is why it takes 6 cycles.

---

## Design iterations: Fmax is not latency

The order book went through five versions. All versions were measured the same way: out of context, `FAST` mode, 10 ns target. The last row is v5 built with full Vivado effort.

| Version | Change | Fmax | Cycles A / E / U | **A** | **E/X/D** | **U** | LUTs |
|---|---|---|---|---|---|---|---|
| v1 | whole message in 1–3 long cycles | 51.0 MHz | 1 / 2 / 3 | **19.6 ns** | 39.2 ns | 58.8 ns | ~17.5k |
| v2 | pipelined: BRAM output register, separate FIND/APPLY | 81.2 MHz | 3 / 5 / 7 | 37.0 ns | 61.6 ns | 86.2 ns | 16.3k |
| v3 | both sides compared in parallel, registered write decisions, no BRAM output register | 96.1 MHz | 3 / 4 / 6 | 31.2 ns | 41.6 ns | 62.4 ns | 15.0k |
| v4 | `live` lookup registered early, quantity compare in parallel with price compare | 104.3 MHz | 3 / 4 / 6 | 28.8 ns | 38.4 ns | 57.5 ns | 19.4k |
| v5 | new quantity precomputed for every level, no 32:1 quantity mux | 108.4 MHz | 3 / 4 / 6 | 27.7 ns | 36.9 ns | 55.4 ns | 17.9k |
| **v5, full effort** | same RTL, default directives + `phys_opt`, 9 ns target | **115.5 MHz** | 3 / 4 / 6 | 26.0 ns | **34.6 ns** | **51.9 ns** | 17.6k |

What the iterations taught:

- **Pipelining alone made things worse.** From v1 to v2 the Fmax went up 59 %, but the latency in nanoseconds went up too, because each message now needed more cycles. For a feed handler, *last byte in → top of book out* in ns is the number that matters.
- **The gains came from removing logic between registers, not from adding cycles.** From v3 to v5 the cycle count stays the same and each version attacks the critical path Vivado reported:
  - v3: a side-select signal with a fanout of 2048 bits.
  - v4: a 1024:1 mux on `live`, and a compare → select → subtract chain.
  - v5: a 32:1 mux that selected the matching level's quantity, replaced by 32 parallel adders. The design still ended up with *fewer* LUTs.
- **v5 is balanced.** Its worst paths are now spread across three unrelated places: the BRAM read into the `E`/`X` decision, the price compare into the prefix-OR that drives the removal shift, and the quantity compare into the "level becomes empty" check. They all fall within about 0.3 ns of each other, and 55–80 % of each path is routing. Going further needs a different architecture (see the roadmap), not another local fix.
- **v1 still has the lowest latency for `A`** (19.6 ns), because it does an add in one long cycle. The pipelined versions win on `E`/`X`/`D` and `U`, and they leave room to overlap messages in the future.

Every version is a commit in the history. v3, v4 and v5 are tagged (`git show v4-104MHz:rtl/order_book.vhd`).

---

## Verification

The source of truth is a **Python reference model** in `model/`. It is an ITCH encoder and parser plus an `OrderBook` that follows SPEC section 5 exactly, including the error rules and the 32-level limit.

| Testbench | Tests | What is checked |
|---|---|---|
| `model/test_model.py` (pytest) | 28 | Byte layouts against the SPEC example, the 7-message scenario, every error rule |
| `tb/parser` | 8 | Every decoded field vs. the model, gaps in `tvalid`, unknown types, wrong lengths, 0-cycle latency |
| `tb/order_book` | 10 | Every `bbo_valid` vs. the model, unknown refs, overfill, level overflow, reset, 3 × 3000 random messages, latency per type |
| `tb/feed_handler` | 6 | End to end: bytes in, top of book out, with random gaps and noise messages; latency per type |

How the comparison works:

- Inputs are driven and outputs are sampled on the falling edge.
- Every output pulse is compared with the model, **in order**, and the number of `err_len` and `err_ref` pulses must match too.
- Latency is checked against a limit for each message type. An optimisation that adds a cycle therefore fails a test, so it cannot slip in unnoticed.
- The random generator ([`model/stream_gen.py`](model/stream_gen.py)) produces consistent order flow: adds within 20 ticks of the mid price, and executions, cancels, deletes and replaces (to fresh refs) on live orders. It also mixes in unsupported message types and messages for other instruments, which must be skipped. The invalid-feed cases (unknown refs, overfills, a full side) have their own directed tests.

**The testbenches are themselves tested.** For v2 to v5, deliberate bugs were injected into the RTL, such as a subtraction turned into an addition, a value taken from the wrong level, or the wrong side selected. Every such bug made at least one test fail.

A simulation-only assertion in `feed_handler.vhd` checks that the parser never delivers a message while the order book is busy.

---

## Repository layout

```
SPEC.md                    behaviour, message formats, interfaces, latency definitions
model/                     Python reference model + pytest tests
rtl/
  itch_pkg.vhd             message types and lengths
  itch_parser.vhd          byte stream -> decoded message
  order_book.vhd           decoded message -> top of book (v5)
  feed_handler.vhd         top level: parser + order book
tb/parser|order_book|feed_handler/
                           cocotb testbenches (Makefile + test_*.py)
vivado/build.tcl           out-of-context synthesis + implementation, writes vivado/out/summary.txt
```

---

## Running it

**Simulation** (Linux or WSL): GHDL 4.x, Python 3.11+.

```bash
sudo apt install ghdl make python3-venv
python3 -m venv ~/fpga-env && source ~/fpga-env/bin/activate
pip install -r requirements.txt

python -m pytest model -v                 # reference model
python -m model.demo                      # SPEC 7.2 scenario, step by step

cd tb/parser       && make && cd ../..
cd tb/order_book   && make && cd ../..
cd tb/feed_handler && make && cd ../..    # one test: make COCOTB_TEST_FILTER=test_latency
```

Waveforms: `make WAVES=1 COCOTB_TEST_FILTER=<test>` in `tb/order_book` or `tb/feed_handler`, then open the `.ghw` file in GTKWave.

**Timing** (Vivado 2024.x, Windows or Linux):

```
cd vivado
vivado -mode batch -source build.tcl
```

The settings are at the top of `build.tcl`: `CLOCK_NS` (target period), `FAST` (1 = quick run with runtime-optimised directives, 0 = default effort + `phys_opt_design`) and `THREADS`. The script writes `vivado/out/summary.txt` (Fmax, critical path, LUT/FF/BRAM counts) and the full timing and utilisation reports. Fmax is computed as `1000 / (CLOCK_NS − WNS)`.

---

## Simplifications

These are deliberate, to keep the scope to a few weeks (SPEC section 8):

- **Message types:** only `A`, `E`, `X`, `D` and `U` update the book. All other types are skipped using the length prefix.
- **Instruments:** one per instance, selected by `stock_locate`.
- **Order references:** limited to 0–1023 so the table can be indexed directly. A real feed needs a hash table for 64-bit references.
- **Price levels:** at most 32 per side.
- **Transport layer:** there is none. There are no MoldUDP64 sequence numbers and no gap recovery; the input is the raw ITCH message stream.

## Roadmap

- **156.25 MHz order book** (the 10G Ethernet MAC clock). Keep only the top N levels in registers and the deeper levels in BRAM, and overlap consecutive messages in the pipeline.
- **64-bit datapath**: 8 bytes per cycle as delivered by a 10G MAC, with messages starting at any byte offset.
- **On hardware**: run on the PYNQ-Z2 with the Zynq PS feeding a recorded ITCH capture over AXI DMA, and measure latency with an on-chip cycle counter.

---

Francisak Prusov · VHDL-2008, GHDL 4.1, cocotb 2.1, Vivado 2024.1
