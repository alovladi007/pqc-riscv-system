"""cocotb test for rtl/sample_ntt.sv.

Drives a 34-byte Kyber-style seed, waits for done, reads the 256
12-bit coefficients via the read port, and compares to
`python/sponge_ref.sample_ntt_from_seed`.
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from sponge_ref import sample_ntt_from_seed  # noqa: E402

CLOCK_PERIOD_NS = 10
N = 256


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
    raise AssertionError(f"sample_ntt did not signal done in {cycle_cap} cycles")


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


async def run_sample(dut, seed):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    await feed_seed(dut, seed)
    await wait_for_done(dut)
    got = await read_poly(dut)
    expected = sample_ntt_from_seed(seed)
    assert got == expected, (
        f"first mismatch: index "
        f"{next(i for i,(g,e) in enumerate(zip(got, expected)) if g != e)}"
        f": got {next(g for g,e in zip(got, expected) if g != e)} "
        f"expected {next(e for g,e in zip(got, expected) if g != e)}"
    )
    # Sanity: every coefficient is < q
    for i, c in enumerate(got):
        assert c < 3329, f"coef[{i}] = {c} >= q"


@cocotb.test()
async def sample_ntt_seed_a(dut):
    """Seed = 34 bytes from RNG seed 0xCAFE."""
    rng = random.Random(0xCAFE)
    seed = bytes(rng.randrange(256) for _ in range(34))
    await run_sample(dut, seed)


@cocotb.test()
async def sample_ntt_seed_b(dut):
    """Seed = 34 bytes from RNG seed 0xBEEF (different distribution)."""
    rng = random.Random(0xBEEF)
    seed = bytes(rng.randrange(256) for _ in range(34))
    await run_sample(dut, seed)


@cocotb.test()
async def sample_ntt_seed_zeros(dut):
    """Edge case: all-zero seed."""
    seed = b"\x00" * 34
    await run_sample(dut, seed)
