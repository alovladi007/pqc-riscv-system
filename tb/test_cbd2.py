"""cocotb test for rtl/sample_poly_cbd2.sv (Kyber CBD η=2 noise sampler)."""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from sponge_ref import sample_cbd2_from_seed  # noqa: E402

CLOCK_PERIOD_NS = 10
N = 256
Q = 3329


async def reset(dut):
    dut.rst_n.value      = 0
    dut.start.value      = 0
    dut.seed_valid.value = 0
    dut.seed_byte.value  = 0
    dut.seed_last.value  = 0
    dut.read_addr.value  = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for_seed_ready(dut):
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        ready = int(dut.seed_ready.value)
        await NextTimeStep()
        if ready:
            return


async def feed_seed(dut, seed):
    for i, b in enumerate(seed):
        await wait_for_seed_ready(dut)
        dut.seed_valid.value = 1
        dut.seed_byte.value  = b
        dut.seed_last.value  = 1 if i == len(seed) - 1 else 0
        await RisingEdge(dut.clk)
        dut.seed_valid.value = 0
        dut.seed_last.value  = 0


async def wait_for_done(dut, cycle_cap=20000):
    for _ in range(cycle_cap):
        await RisingEdge(dut.clk)
        await ReadOnly()
        d = int(dut.done.value)
        await NextTimeStep()
        if d:
            return
    raise AssertionError(f"cbd2 did not signal done in {cycle_cap} cycles")


async def read_poly(dut):
    out = []
    for i in range(N):
        dut.read_addr.value = i
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        await ReadOnly()
        out.append(int(dut.read_data.value))
        await NextTimeStep()
    return out


async def run_cbd(dut, sigma, nonce):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    await feed_seed(dut, sigma + bytes([nonce]))
    await wait_for_done(dut)
    got = await read_poly(dut)
    expected = sample_cbd2_from_seed(sigma, nonce)
    assert got == expected, (
        f"first mismatch at index "
        f"{next(i for i,(g,e) in enumerate(zip(got, expected)) if g != e)}"
    )
    # All coefficients must be in {0, 1, 2, q-2, q-1} for η=2.
    valid = {0, 1, 2, Q - 1, Q - 2}
    for i, c in enumerate(got):
        assert c in valid, f"coef[{i}] = {c} not a valid CBD-2 output"


@cocotb.test()
async def cbd2_seed_a(dut):
    """Random sigma, nonce = 0."""
    rng = random.Random(0xCAFE)
    sigma = bytes(rng.randrange(256) for _ in range(32))
    await run_cbd(dut, sigma, 0)


@cocotb.test()
async def cbd2_seed_b_nonce_42(dut):
    """Random sigma, nonce = 42 — covers a different SHAKE state."""
    rng = random.Random(0xBEEF)
    sigma = bytes(rng.randrange(256) for _ in range(32))
    await run_cbd(dut, sigma, 42)


@cocotb.test()
async def cbd2_zero_seed(dut):
    """All-zero seed, nonce = 0 — edge case for the CBD pipeline."""
    await run_cbd(dut, b"\x00" * 32, 0)
