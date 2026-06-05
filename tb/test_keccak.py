"""cocotb test for rtl/keccak_f1600.sv.

Loads a 25-lane state into the RTL, pulses `start`, waits for `done`,
reads the state back, and compares against python/keccak_ref.py bit-exactly.
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from keccak_ref import keccak_f1600  # noqa: E402

CLOCK_PERIOD_NS = 10
NUM_LANES = 25


async def reset(dut):
    dut.rst_n.value     = 0
    dut.start.value     = 0
    dut.load_en.value   = 0
    dut.load_addr.value = 0
    dut.load_data.value = 0
    dut.read_addr.value = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_state(dut, state):
    assert len(state) == NUM_LANES
    for i, lane in enumerate(state):
        dut.load_en.value   = 1
        dut.load_addr.value = i
        dut.load_data.value = lane & ((1 << 64) - 1)
        await RisingEdge(dut.clk)
    dut.load_en.value = 0
    await RisingEdge(dut.clk)


async def read_state(dut):
    """Read all 25 lanes via the combinational read port.

    Use the canonical cocotb pattern: wait for the clock edge (which
    triggers any NBAs / always_ff updates), then `await ReadOnly()`
    to settle into the read-only phase where all combinational
    propagation has resolved. Without ReadOnly, Icarus samples
    `read_data` before the `assign read_data = state[read_addr]`
    has propagated the new address — that produced X reads even
    though the RTL state itself was correct (confirmed by a pure-SV
    testbench: f^24(0) lane 0 matches the published Keccak-Team
    constant 0xF1258F7940E1DDE7).
    """
    out = []
    for i in range(NUM_LANES):
        dut.read_addr.value = i
        await RisingEdge(dut.clk)
        await ReadOnly()
        out.append(int(dut.read_data.value))
        # Exit the read-only phase so the next iteration's write to
        # read_addr.value is accepted by the scheduler.
        await NextTimeStep()
    return out


async def run_permutation(dut, state_in):
    await load_state(dut, state_in)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    # 24 rounds + control overhead — generous cap
    for _ in range(60):
        await RisingEdge(dut.clk)
        if int(dut.done.value) == 1:
            break
    else:
        raise AssertionError("Keccak-f did not finish within 60 cycles")
    return await read_state(dut)


def _first_lane_mismatch(got, exp, label):
    for i, (g, e) in enumerate(zip(got, exp)):
        if g != e:
            return (
                f"{label}: first lane mismatch at index {i}: "
                f"got 0x{g:016x}, expected 0x{e:016x}"
            )
    return f"{label}: lengths differ"


@cocotb.test()
async def keccak_zero_state(dut):
    """Keccak-f[1600] applied to the all-zero state.

    Output is a well-known constant (the 24-round transform of zero).
    Anything that doesn't match the Python ref means the round constants,
    rho offsets, or chi mixing are wrong somewhere.
    """
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    got = await run_permutation(dut, [0] * NUM_LANES)
    expected = keccak_f1600([0] * NUM_LANES)
    assert got == expected, _first_lane_mismatch(got, expected, "zero")


@cocotb.test()
async def keccak_random(dut):
    """Random state — covers the data-dependent paths."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    rng = random.Random(0xDEADBEEF)
    state = [rng.getrandbits(64) for _ in range(NUM_LANES)]
    got = await run_permutation(dut, state)
    expected = keccak_f1600(state)
    assert got == expected, _first_lane_mismatch(got, expected, "random")


@cocotb.test()
async def keccak_two_permutations_compose(dut):
    """f(f(x)) — make sure the controller resets cleanly between runs.

    Many subtle bugs only show up on the second invocation (latched state,
    counter not resetting, etc).
    """
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    rng = random.Random(0xC0DE)
    state = [rng.getrandbits(64) for _ in range(NUM_LANES)]

    after_one = await run_permutation(dut, state)
    after_two = await run_permutation(dut, after_one)

    expected_one = keccak_f1600(state)
    expected_two = keccak_f1600(expected_one)
    assert after_one == expected_one, _first_lane_mismatch(after_one, expected_one, "first")
    assert after_two == expected_two, _first_lane_mismatch(after_two, expected_two, "second")
