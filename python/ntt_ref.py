"""
NTT reference for Kyber768 (q = 3329, n = 256).

This module is the golden model the SystemVerilog NTT engine is verified
against. It is intentionally written to mirror the structure of the RTL
(in-place radix-2 NTT with bit-reversed output order) rather than to be the
fastest possible Python implementation.

References
----------
- Avanzi et al, "CRYSTALS-Kyber Algorithm Specifications and Supporting
  Documentation", NIST PQC Round 3 submission, 2021.
- NIST FIPS 203, "Module-Lattice-Based Key-Encapsulation Mechanism Standard",
  August 2024.
- pq-crystals/kyber reference implementation, https://github.com/pq-crystals/kyber

Parameter q = 3329 is prime, and 256 = 2^8 divides q - 1 = 2^8 * 13, so a
primitive 256-th root of unity exists in GF(q). Kyber uses zeta = 17 as a
generator (zeta^128 = -1 mod q). The NTT used in Kyber is over the ring
Z_q[X]/(X^256 + 1), which factors into 128 degree-2 polynomials in NTT
domain (not 256 degree-1 — the "incomplete NTT").
"""

from __future__ import annotations
from typing import List

Q = 3329
N = 256
ZETA = 17  # 256-th root of unity mod Q; equivalently 128-th root of -1

# Precomputed zetas in bit-reversed order, as used by the canonical Kyber
# reference. Values match pq-crystals/kyber's `zetas[]` table.
# zetas[i] = ZETA ** br7(i) mod Q  for i = 0..127, where br7 is 7-bit bit-reverse.

def _bitrev7(i: int) -> int:
    """7-bit bit reversal used to index the zetas table."""
    return int(format(i, "07b")[::-1], 2)


def _gen_zetas() -> List[int]:
    """Generate zetas[1..127] in bit-reversed order. zetas[0] is unused."""
    return [pow(ZETA, _bitrev7(i), Q) for i in range(128)]


ZETAS = _gen_zetas()


def _mod_q(x: int) -> int:
    """Centred reduction is not used; we keep [0, Q) representation."""
    return x % Q


def ntt(poly: List[int]) -> List[int]:
    """In-place "incomplete" NTT used by Kyber. Operates on a 256-coefficient
    polynomial in Z_q[X]/(X^256 + 1), produces 128 degree-2 polynomials in
    NTT domain.

    Bit-exact match for pq-crystals/kyber `poly_ntt()` followed by
    `poly_reduce()`.
    """
    if len(poly) != N:
        raise ValueError(f"poly must have {N} coefficients, got {len(poly)}")
    f = [c % Q for c in poly]

    k = 1
    length = 128
    while length >= 2:
        start = 0
        while start < N:
            zeta = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                t = (zeta * f[j + length]) % Q
                f[j + length] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
            start += 2 * length
        length //= 2

    return f


def inv_ntt(poly: List[int]) -> List[int]:
    """Inverse of `ntt`. Includes the final multiplication by n^-1 mod q
    (= 3303 for Kyber's n = 256, q = 3329, since the loop only halves 7
    times — Kyber uses an "incomplete" NTT, see Avanzi et al §1.1).
    """
    if len(poly) != N:
        raise ValueError(f"poly must have {N} coefficients, got {len(poly)}")
    f = [c % Q for c in poly]

    k = 127
    length = 2
    while length <= 128:
        start = 0
        while start < N:
            zeta = ZETAS[k]
            k -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (t + f[j + length]) % Q
                f[j + length] = (zeta * (f[j + length] - t)) % Q
            start += 2 * length
        length *= 2

    # Final scaling by f = 3303 = mont_R * n^-1 mod q (or just n^-1 = 3303
    # in our non-Montgomery representation since 256 * 3303 mod 3329 = 1).
    f_inv = 3303
    return [(c * f_inv) % Q for c in f]


def basemul(a: List[int], b: List[int], zeta: int) -> List[int]:
    """Schoolbook multiplication of two degree-1 polynomials in Z_q[X]/(X^2 - zeta).
    Used inside `ntt_mul` for the 128 degree-2 components in NTT domain.
    """
    r0 = (a[0] * b[0] + zeta * a[1] * b[1]) % Q
    r1 = (a[0] * b[1] + a[1] * b[0]) % Q
    return [r0, r1]


def ntt_mul(a: List[int], b: List[int]) -> List[int]:
    """Multiplication in NTT domain. Both inputs must already be in NTT
    representation. Output is also in NTT representation.
    """
    result = [0] * N
    for i in range(64):
        zeta = ZETAS[64 + i]
        r0r1 = basemul([a[4 * i], a[4 * i + 1]], [b[4 * i], b[4 * i + 1]], zeta)
        result[4 * i] = r0r1[0]
        result[4 * i + 1] = r0r1[1]
        r2r3 = basemul([a[4 * i + 2], a[4 * i + 3]], [b[4 * i + 2], b[4 * i + 3]], -zeta % Q)
        result[4 * i + 2] = r2r3[0]
        result[4 * i + 3] = r2r3[1]
    return result


def poly_add(a: List[int], b: List[int]) -> List[int]:
    return [(x + y) % Q for x, y in zip(a, b)]


def poly_sub(a: List[int], b: List[int]) -> List[int]:
    return [(x - y) % Q for x, y in zip(a, b)]
