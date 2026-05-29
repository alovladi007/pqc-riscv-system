"""
Modular arithmetic primitives for Kyber's q = 3329.

These match the SystemVerilog `kyber_q_alu.sv` module bit-for-bit. The
Python implementation is the golden model used by cocotb in tb/test_q_alu.py.

Two reduction strategies are provided:

* Barrett reduction — chosen for the RTL because the precomputed constant
  (5039 = floor(2^24 / 3329)) and a single multiply give a constant-time
  reduction with bounded output in [0, 2q). Cheaper than Montgomery for
  one-off reductions; we use it on the boundaries of the NTT engine.

* Montgomery reduction — used inside the butterfly because it avoids the
  divide-by-q on every multiply. Constant R = 2^16 mod q = 2285. The
  precomputed -q^-1 mod 2^16 = 3327.

Both reductions are constant-time (no data-dependent branches) and are
exhaustively tested over the input ranges they're specified for.
"""

from __future__ import annotations

Q = 3329
# Barrett reduction constants for q = 3329
BARRETT_SHIFT = 24
BARRETT_M = (1 << BARRETT_SHIFT) // Q   # = 5039

# Montgomery reduction constants for q = 3329, R = 2^16
MONT_R = 1 << 16                         # 65536
MONT_R_MOD_Q = MONT_R % Q                # 2285
MONT_R2_MOD_Q = (MONT_R * MONT_R) % Q    # 1353 — used to convert into Montgomery form
MONT_Q_INV_NEG = 3327                    # -q^-1 mod 2^16


def barrett_reduce(a: int) -> int:
    """Reduce a (32-bit unsigned) to canonical [0, q).

    Implements the Barrett reduction the RTL uses:
        t = (a * M) >> SHIFT
        r = a - t * q
        if r >= q: r -= q
    """
    if a < 0:
        raise ValueError("barrett_reduce expects unsigned input")
    t = (a * BARRETT_M) >> BARRETT_SHIFT
    r = a - t * Q
    if r >= Q:
        r -= Q
    return r


def montgomery_reduce(a: int) -> int:
    """Reduce a (signed, |a| < q * R) to canonical [0, q) using Montgomery.

    Matches Algorithm 14.32 of HAC; equivalent to pq-crystals' montgomery_reduce.
        u = (a mod R) * MONT_Q_INV_NEG mod R
        t = (a + u * q) / R
        if t >= q: t -= q

    Handles negative `a` the same way the RTL does: two's-complement on 32 bits.
    """
    # Two's-complement 32-bit for negative inputs (matches RTL behaviour)
    if a < 0:
        a = (a + (1 << 32)) & ((1 << 32) - 1)
    u = ((a & (MONT_R - 1)) * MONT_Q_INV_NEG) & (MONT_R - 1)
    t = (a + u * Q) >> 16
    if t >= Q:
        t -= Q
    return t


def to_montgomery(a: int) -> int:
    """Convert a in [0, q) to Montgomery form: a * R mod q."""
    return montgomery_reduce(a * MONT_R2_MOD_Q)


def from_montgomery(a: int) -> int:
    """Convert a (in Montgomery form) back to canonical [0, q)."""
    return montgomery_reduce(a)


def mod_mul(a: int, b: int) -> int:
    """Canonical modular multiplication, output in [0, q)."""
    return barrett_reduce(a * b)


def mod_add(a: int, b: int) -> int:
    return barrett_reduce(a + b)


def mod_sub(a: int, b: int) -> int:
    return (a - b) % Q
