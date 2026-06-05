"""cocotb test for rtl/ntt_butterfly.sv.

Drives random (a, b, zeta) into the butterfly and compares the (a', b')
outputs against the Python reference computed from python/ntt_ref.py's
arithmetic (the butterfly's mathematical form is in Avanzi et al §1.1):

    t  = (zeta * b) mod q
    a' = (a + t)    mod q
    b' = (a - t)    mod q

The RTL butterfly is two-cycle pipelined: cycle 0 captures inputs and
fires the multiplier, cycle 1 does Montgomery reduce + add/sub, valid_out
asserts on cycle 2.
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from mod_arith import Q, MONT_R_MOD_Q  # noqa: E402

CLOCK_PERIOD_NS = 10


def butterfly_ref(a, b, zeta_canonical):
    """Spec-form Cooley-Tukey butterfly. Output in canonical [0, q).

    Takes zeta in canonical form. The RTL butterfly expects zeta already
    in Montgomery form (so its internal Montgomery reduce of zeta*b
    produces a canonical result). The testbench is responsible for
    converting zeta to Montgomery form before driving the DUT — this
    reference computes against the canonical form for clarity.
    """
    t = (zeta_canonical * b) % Q
    return (a + t) % Q, (a - t) % Q


def to_montgomery(x):
    """Convert canonical x in [0, Q) to Montgomery form: (x * R) mod Q."""
    return (x * MONT_R_MOD_Q) % Q


async def reset(dut):
    dut.rst_n.value    = 0
    dut.valid_in.value = 0
    dut.a.value        = 0
    dut.b.value        = 0
    dut.zeta.value     = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue_and_capture(dut, a, b, zeta_canonical):
    """Apply one butterfly op and capture the output 3 cycles later.

    `zeta_canonical` is the mathematical twiddle value; we convert it
    to Montgomery form before driving the DUT, because the RTL
    Montgomery-reduces zeta*b internally.
    """
    dut.a.value        = a
    dut.b.value        = b
    dut.zeta.value     = to_montgomery(zeta_canonical)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    # 2-stage pipeline + output register => 3 clocks total
    for _ in range(3):
        await RisingEdge(dut.clk)
    return int(dut.a_out.value), int(dut.b_out.value), int(dut.valid_out.value)


@cocotb.test()
async def butterfly_zero(dut):
    """(0, 0, *) -> (0, 0)."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)
    a_out, b_out, valid = await issue_and_capture(dut, 0, 0, 17)
    assert (a_out, b_out) == (0, 0), f"zero butterfly: got ({a_out}, {b_out})"
    assert valid == 1


@cocotb.test()
async def butterfly_random(dut):
    """Random vectors covering the input range."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    rng = random.Random(0xBABE)
    fails = 0
    first_fail = None
    for _ in range(200):
        a    = rng.randrange(0, Q)
        b    = rng.randrange(0, Q)
        zeta = rng.randrange(0, Q)
        ga, gb, _ = await issue_and_capture(dut, a, b, zeta)
        ea, eb = butterfly_ref(a, b, zeta)
        if (ga, gb) != (ea, eb):
            fails += 1
            if first_fail is None:
                first_fail = (a, b, zeta, ga, gb, ea, eb)
    assert fails == 0, (
        f"{fails} butterfly mismatches; first: a={first_fail[0]} b={first_fail[1]} "
        f"zeta={first_fail[2]} got=({first_fail[3]},{first_fail[4]}) "
        f"exp=({first_fail[5]},{first_fail[6]})"
    )


@cocotb.test()
async def butterfly_corners(dut):
    """Corner cases that catch off-by-one in Montgomery / mod arithmetic."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)

    corners = [
        (0, 0, 0),
        (0, 1, 1),
        (Q - 1, Q - 1, Q - 1),
        (Q - 1, 0, 0),
        (1, Q - 1, Q - 1),
        (Q // 2, Q // 2, Q // 2),
    ]
    for a, b, zeta in corners:
        ga, gb, _ = await issue_and_capture(dut, a, b, zeta)
        ea, eb = butterfly_ref(a, b, zeta)
        assert (ga, gb) == (ea, eb), (
            f"corner a={a} b={b} zeta={zeta}: got ({ga},{gb}) exp ({ea},{eb})"
        )
