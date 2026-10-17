import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

WIDTH = 8
MAX = 2**WIDTH


async def reset(dut):
    """Houd reset 2 klokcycli hoog, laat los op een dalende flank."""
    dut.rst.value = 1
    dut.en.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


@cocotb.test()
async def test_counts_and_wraps(dut):
    """Teller telt elke cyclus +1 en springt van 255 naar 0."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)
    assert dut.count.value.to_unsigned() == 0

    dut.en.value = 1
    expected = 0
    for cycle in range(300):  # > 256, dus de wraparound wordt getest
        await FallingEdge(dut.clk)
        expected = (expected + 1) % MAX
        got = dut.count.value.to_unsigned()
        assert got == expected, f"cyclus {cycle}: verwacht {expected}, kreeg {got}"


@cocotb.test()
async def test_enable_holds(dut):
    """Met en = 0 blijft de waarde staan."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)

    dut.en.value = 1
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    assert dut.count.value.to_unsigned() == 5

    dut.en.value = 0
    for _ in range(10):
        await FallingEdge(dut.clk)
        assert dut.count.value.to_unsigned() == 5

    dut.en.value = 1
    await FallingEdge(dut.clk)
    assert dut.count.value.to_unsigned() == 6