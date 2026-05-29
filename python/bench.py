#!/usr/bin/env python3
"""Benchmark harness for the Python reference.

Measures wall-clock time for the NTT, inverse NTT, and pointwise multiply.
Numbers from this script are the *software baseline* against which the RTL
acceleration is reported.

Usage:
    python bench.py [--iters N]
"""

from __future__ import annotations
import argparse
import random
import sys
import time

# Make the package importable when run directly
sys.path.insert(0, ".")

from ntt_ref import ntt, inv_ntt, ntt_mul, N, Q
from mod_arith import barrett_reduce, montgomery_reduce, to_montgomery


def bench(fn, *args, iters=1000):
    """Run fn(*args) `iters` times. Return (avg_us, min_us)."""
    # Warm-up
    for _ in range(min(50, iters)):
        fn(*args)

    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        fn(*args)
        samples.append(time.perf_counter_ns() - t0)
    avg = sum(samples) / len(samples) / 1000.0
    best = min(samples) / 1000.0
    return avg, best


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--iters", type=int, default=200,
                   help="Iterations per measurement (default: 200)")
    args = p.parse_args()

    rng = random.Random(0xC0FFEE)
    a = [rng.randrange(Q) for _ in range(N)]
    b = [rng.randrange(Q) for _ in range(N)]
    a_ntt = ntt(a[:])
    b_ntt = ntt(b[:])

    print(f"Kyber768 NTT reference benchmark — q={Q}, n={N}, iters={args.iters}")
    print("-" * 70)
    print(f"{'op':<25}{'avg (µs)':>14}{'best (µs)':>14}{'ops/sec':>16}")
    print("-" * 70)

    for name, fn, fargs in [
        ("ntt", ntt, (a[:],)),
        ("inv_ntt", inv_ntt, (a_ntt[:],)),
        ("ntt_mul (pointwise)", ntt_mul, (a_ntt, b_ntt)),
        ("barrett_reduce", barrett_reduce, (Q * Q + 1,)),
        ("montgomery_reduce", montgomery_reduce, (Q * Q + 1,)),
        ("to_montgomery", to_montgomery, (1234,)),
    ]:
        avg, best = bench(fn, *fargs, iters=args.iters)
        ops_per_sec = 1e6 / best if best > 0 else 0
        print(f"{name:<25}{avg:>14.2f}{best:>14.2f}{ops_per_sec:>16.0f}")

    print("-" * 70)
    print("\nThese are SOFTWARE numbers from a pure-Python reference. The point")
    print("of the RTL is to beat them by 1-2 orders of magnitude. Phase 3 of")
    print("this project will back-annotate the RTL numbers here.")


if __name__ == "__main__":
    main()
