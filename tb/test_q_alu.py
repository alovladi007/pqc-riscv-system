"""cocotb test for kyber_q_alu.sv.

Loads the Python golden model from ../python/mod_arith.py and compares
the RTL's Barrett / mod_add / mod_sub outputs against it. Random vectors
cover the input ranges the RTL is specified for.
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# Ensure the python/ directory is on the import path. The Makefile already
# sets PYTHONPATH, but be defensive.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from mod_arith import Q, barrett_reduce, mod_add, mod_sub  # noqa: E402


OP_BARRETT = 0
OP_ADD     = 1
OP_SUB     = 2


async def reset(dut):
    dut.rst_n.value = 0
    dut.op.value    = 0
    dut.in_a.value  = 0
    dut.in_b.value  = 0
    await Timer(20, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def apply_op(dut, op, a, b=0):
    """Drive an op and return the output two cycles later (registered)."""
    dut.op.value   = op
    dut.in_a.value = a & ((1 << 24) - 1)
    dut.in_b.value = b & ((1 << 24) - 1)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    return int(dut.out.value)


@cocotb.test()
async def barrett_random(dut):
    """Random Barrett reductions over [0, 2^24)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    rng = random.Random(0xC0FFEE)
    for _ in range(500):
        a = rng.randrange(0, 1 << 24)
        got = await apply_op(dut, OP_BARRETT, a)
        exp = barrett_reduce(a)
        assert got == exp, f"barrett({a}): got {got}, expected {exp}"


@cocotb.test()
async def barrett_corners(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    corners = [0, 1, Q - 1, Q, Q + 1, 2 * Q - 1, 2 * Q, Q * Q, (1 << 24) - 1]
    for a in corners:
        got = await apply_op(dut, OP_BARRETT, a)
        exp = barrett_reduce(a)
        assert got == exp, f"barrett corner({a}): got {got}, expected {exp}"


@cocotb.test()
async def mod_add_random(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    rng = random.Random(42)
    for _ in range(500):
        a = rng.randrange(0, Q)
        b = rng.randrange(0, Q)
        got = await apply_op(dut, OP_ADD, a, b)
        exp = mod_add(a, b)
        assert got == exp, f"add({a}, {b}): got {got}, expected {exp}"


@cocotb.test()
async def mod_sub_random(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    rng = random.Random(123)
    for _ in range(500):
        a = rng.randrange(0, Q)
        b = rng.randrange(0, Q)
        got = await apply_op(dut, OP_SUB, a, b)
        exp = mod_sub(a, b)
        assert got == exp, f"sub({a}, {b}): got {got}, expected {exp}"
