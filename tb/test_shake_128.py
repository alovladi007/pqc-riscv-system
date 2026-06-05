"""cocotb test for rtl/shake_128.sv.

Streams input + collects output, compares against `python/sponge_ref.shake_128`
(cross-validated against hashlib).
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from sponge_ref import shake_128, RATE_SHAKE_128  # noqa: E402

CLOCK_PERIOD_NS = 10


async def reset(dut):
    dut.rst_n.value         = 0
    dut.start.value         = 0
    dut.out_bytes_req.value = 0
    dut.in_valid.value      = 0
    dut.in_byte.value       = 0
    dut.in_last.value       = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for_in_ready(dut):
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        ready = int(dut.in_ready.value)
        await NextTimeStep()
        if ready:
            return


async def push_message(dut, msg):
    for i, b in enumerate(msg):
        await wait_for_in_ready(dut)
        dut.in_valid.value = 1
        dut.in_byte.value  = b
        dut.in_last.value  = 1 if i == len(msg) - 1 else 0
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.in_last.value  = 0


async def collect_output(dut, n_bytes, cycle_cap=8000):
    out = bytearray()
    for _ in range(cycle_cap):
        await RisingEdge(dut.clk)
        await ReadOnly()
        valid = int(dut.out_valid.value)
        byte  = int(dut.out_byte.value) if valid else None
        await NextTimeStep()
        if valid:
            out.append(byte)
            if len(out) == n_bytes:
                return bytes(out)
    raise AssertionError(
        f"output not complete: got {len(out)}/{n_bytes} bytes "
        f"after {cycle_cap} cycles"
    )


async def run_shake_128(dut, msg, out_len):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)
    dut.out_bytes_req.value = out_len
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    await push_message(dut, msg)
    got = await collect_output(dut, out_len)
    expected = shake_128(msg, out_len)
    assert got == expected, (
        f"len={len(msg)}, out_len={out_len}:\n"
        f"  got      {got.hex()}\n"
        f"  expected {expected.hex()}"
    )


@cocotb.test()
async def shake_short_short(dut):
    """3-byte input, 16-byte output (single squeeze block)."""
    await run_shake_128(dut, b"abc", 16)


@cocotb.test()
async def shake_short_full_rate(dut):
    """3-byte input, exactly RATE bytes output (single permute)."""
    await run_shake_128(dut, b"abc", RATE_SHAKE_128)


@cocotb.test()
async def shake_short_two_rates(dut):
    """3-byte input, output crosses one squeeze-rate boundary (two permutes)."""
    await run_shake_128(dut, b"abc", RATE_SHAKE_128 + 8)


@cocotb.test()
async def shake_random_long(dut):
    """100-byte random input, 256-byte output (covers Kyber-style usage)."""
    rng = random.Random(0xDEED)
    msg = bytes(rng.randrange(256) for _ in range(100))
    await run_shake_128(dut, msg, 256)


@cocotb.test()
async def shake_kyber_seed(dut):
    """34-byte Kyber-style seed (rho || j || i), 1024-byte output —
    exact pattern the rejection sampler uses."""
    rng = random.Random(0xC0FE)
    seed = bytes(rng.randrange(256) for _ in range(34))
    await run_shake_128(dut, seed, 1024)
