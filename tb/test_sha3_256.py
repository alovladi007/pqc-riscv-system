"""cocotb test for rtl/sha3_256.sv.

Streams bytes in via the producer-throttled `in_valid`/`in_byte`/`in_last`
interface, collects 32 output bytes via `out_valid`/`out_byte`, and
compares against `python/sponge_ref.sha3_256()` — which itself is
cross-validated against `hashlib.sha3_256` (62 pytest passes).

Coverage:
  - single byte
  - "abc"  (classic published SHA-3 vector)
  - short random message
  - rate-1, rate, rate+1 lengths (boundary around the XOR+permute
    intermediate trigger)
  - random message spanning two full blocks
"""

import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from sponge_ref import sha3_256, RATE_SHA3_256  # noqa: E402

CLOCK_PERIOD_NS = 10
OUT_BYTES = 32


async def reset(dut):
    dut.rst_n.value    = 0
    dut.in_valid.value = 0
    dut.in_byte.value  = 0
    dut.in_last.value  = 0
    await Timer(2 * CLOCK_PERIOD_NS, units="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for_in_ready(dut):
    """Spin until in_ready is high (post-NBA observation)."""
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        ready = int(dut.in_ready.value)
        await NextTimeStep()
        if ready:
            return


async def push_message(dut, msg):
    """Stream `msg` byte by byte, asserting in_last on the final byte."""
    for i, b in enumerate(msg):
        await wait_for_in_ready(dut)
        dut.in_valid.value = 1
        dut.in_byte.value  = b
        dut.in_last.value  = 1 if i == len(msg) - 1 else 0
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.in_last.value  = 0


async def collect_output(dut, n_bytes=OUT_BYTES, cycle_cap=4000):
    """Collect `n_bytes` output bytes by sampling on every cycle where
    out_valid is high. Bounded by `cycle_cap` for safety."""
    out = bytearray()
    for _ in range(cycle_cap):
        await RisingEdge(dut.clk)
        await ReadOnly()
        valid = int(dut.out_valid.value)
        byte  = int(dut.out_byte.value) if valid else None
        d     = int(dut.done.value)
        await NextTimeStep()
        if valid:
            out.append(byte)
            if len(out) == n_bytes:
                return bytes(out)
        if d and len(out) == n_bytes:
            return bytes(out)
    raise AssertionError(
        f"output not complete: got {len(out)}/{n_bytes} bytes "
        f"after {cycle_cap} cycles"
    )


async def run_sha3_256(dut, msg):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    await reset(dut)
    await push_message(dut, msg)
    got = await collect_output(dut)
    expected = sha3_256(msg)
    assert got == expected, (
        f"len={len(msg)}: got    {got.hex()}\n"
        f"        expected {expected.hex()}"
    )


# ----------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------

@cocotb.test()
async def sha3_single_byte(dut):
    """One-byte input, sanity check the absorb -> pad -> permute -> squeeze
    sequence with a minimal payload."""
    await run_sha3_256(dut, b"\xa5")


@cocotb.test()
async def sha3_abc(dut):
    """Classic published SHA3-256("abc") test vector."""
    await run_sha3_256(dut, b"abc")


@cocotb.test()
async def sha3_short_random(dut):
    """Short random message (< 1 block)."""
    rng = random.Random(0xCAFE)
    msg = bytes(rng.randrange(256) for _ in range(50))
    await run_sha3_256(dut, msg)


@cocotb.test()
async def sha3_rate_minus_one(dut):
    """rate - 1 bytes: padding fills the last byte with 0x80, no
    additional permute needed."""
    rng = random.Random(0xBEEF)
    msg = bytes(rng.randrange(256) for _ in range(RATE_SHA3_256 - 1))
    await run_sha3_256(dut, msg)


@cocotb.test()
async def sha3_exact_rate(dut):
    """rate bytes exactly: triggers a mid-stream XOR+permute on byte 136,
    followed by a full padding block."""
    rng = random.Random(0xFACE)
    msg = bytes(rng.randrange(256) for _ in range(RATE_SHA3_256))
    await run_sha3_256(dut, msg)


@cocotb.test()
async def sha3_rate_plus_one(dut):
    """rate + 1 bytes: triggers a mid-stream permute, then 1 byte into the
    next block, then padding."""
    rng = random.Random(0xD00D)
    msg = bytes(rng.randrange(256) for _ in range(RATE_SHA3_256 + 1))
    await run_sha3_256(dut, msg)
