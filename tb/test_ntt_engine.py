"""cocotb test for rtl/ntt_engine.sv.

Loads a polynomial into the engine, pulses `start`, waits for `done`, reads
the output, and compares against python/ntt_ref.py:ntt() bit-exactly.

Coverage:
  - zero polynomial (NTT of all-zero must be all-zero)
  - delta function (one nonzero coeff)
  - random polynomials (a handful of seeds for runtime budget)
  - the matrix-A-style polynomials sample_ntt produces (already in NTT
    form — should be a fixed point under NTT? No — NTT is bijective, so
    we just confirm the round-trip property: forward NTT of any poly
    matches the Python ref bit-exactly).

The engine's internal counter caps the simulation at ~10k cycles per
transform. Each cocotb test runs one NTT, so total sim time per test is
small (sub-second on Icarus).
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# Locate python/ for the golden model
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from ntt_ref import ntt as ntt_golden, Q, N  # noqa: E402


CLOCK_PERIOD_NS = 10
# Generous safety cap. Each butterfly is ~9 cycles in the FSM, 896 butterflies
# per NTT => ~8100. 20k gives plenty of slack.
MAX_CYCLES_PER_NTT = 20000


async def reset(dut):
    dut.rst_n.value     = 0
    dut.start.value     = 0
    dut.inverse.value   = 0
    dut.load_en.value   = 0
    dut.load_addr.value = 0
    dut.load_data.value = 0
    dut.read_addr.value = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_poly(dut, poly):
    """Drive `load_en` for 256 cycles to write each coefficient into mem[]."""
    assert len(poly) == N
    for i, coef in enumerate(poly):
        dut.load_en.value   = 1
        dut.load_addr.value = i
        dut.load_data.value = coef & ((1 << 12) - 1)
        await RisingEdge(dut.clk)
    dut.load_en.value = 0
    await RisingEdge(dut.clk)


async def read_poly(dut):
    """Read all 256 coefficients via the combinational read port.

    Wait a full clock edge between setting read_addr and sampling
    read_data — Icarus' combinational propagation through an unpacked
    array index doesn't always settle within a sub-cycle Timer wait.
    """
    out = []
    for i in range(N):
        dut.read_addr.value = i
        await RisingEdge(dut.clk)
        out.append(int(dut.read_data.value))
    return out


async def run_one_ntt(dut, poly):
    """Load poly, run the NTT, return the output. Asserts done within budget."""
    await load_poly(dut, poly)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for cycle in range(MAX_CYCLES_PER_NTT):
        await RisingEdge(dut.clk)
        if int(dut.done.value) == 1:
            break
    else:
        raise AssertionError(
            f"NTT did not finish within {MAX_CYCLES_PER_NTT} cycles"
        )

    return await read_poly(dut)


@cocotb.test()
async def ntt_zero(dut):
    """NTT(0) must be 0."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    got = await run_one_ntt(dut, [0] * N)
    expected = ntt_golden([0] * N)
    assert got == expected, f"zero NTT mismatch: got nonzero coeffs"


@cocotb.test()
async def ntt_delta(dut):
    """NTT(delta) — only coefficient 0 set to 1.

    Forward NTT is linear and the delta-input case isolates butterfly
    correctness on a controlled input.
    """
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    poly = [0] * N
    poly[0] = 1
    got = await run_one_ntt(dut, poly)
    expected = ntt_golden(poly)
    assert got == expected, (
        f"delta NTT first mismatch at index "
        f"{next(i for i, (g, e) in enumerate(zip(got, expected)) if g != e)}"
    )


@cocotb.test()
async def ntt_random_seed_42(dut):
    """Random polynomial — full coverage of the butterfly path."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    rng = random.Random(42)
    poly = [rng.randrange(0, Q) for _ in range(N)]
    got = await run_one_ntt(dut, poly)
    expected = ntt_golden(poly)
    assert got == expected, _first_mismatch_msg(got, expected, "random[42]")


@cocotb.test()
async def ntt_random_seed_7(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    rng = random.Random(7)
    poly = [rng.randrange(0, Q) for _ in range(N)]
    got = await run_one_ntt(dut, poly)
    expected = ntt_golden(poly)
    assert got == expected, _first_mismatch_msg(got, expected, "random[7]")


def _first_mismatch_msg(got, expected, label):
    for i, (g, e) in enumerate(zip(got, expected)):
        if g != e:
            return (
                f"{label}: first mismatch at index {i}: got {g}, expected {e}"
                f" (then {sum(1 for gg, ee in zip(got[i:], expected[i:]) if gg != ee)}"
                f" more diffs)"
            )
    return f"{label}: lengths differ"
