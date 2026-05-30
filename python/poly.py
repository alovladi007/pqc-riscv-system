"""
Polynomial-byte conversions and sampling for Kyber per FIPS 203 §4.2.

Each Kyber polynomial is 256 coefficients in Z_q (q = 3329). The byte
representation packs each coefficient into d bits, where d depends on
context (12 for raw polynomials, 1/4/5/10/11 for compressed forms).

Functions implemented here:

  byte_encode(d, poly)    -> bytes
  byte_decode(d, data)    -> poly
  compress(d, poly)       -> poly with coeffs in [0, 2^d)
  decompress(d, poly)     -> poly in Z_q
  sample_ntt(xof_stream)  -> NTT-domain poly via rejection sampling
  sample_poly_cbd(eta, bytes_)
                          -> poly with CBD(eta) noise

Together with mod_arith.py and ntt_ref.py, these are all the polynomial
machinery the K-PKE and ML-KEM top-level functions need.
"""

from __future__ import annotations
from typing import List

Q = 3329
N = 256


# -----------------------------------------------------------------------------
# Compress / Decompress  (FIPS 203 §4.2.1, eqs 4.7–4.8)
# -----------------------------------------------------------------------------
#
# compress_d(x) = round( (2^d / q) * x ) mod 2^d
# decompress_d(y) = round( (q / 2^d) * y )
#
# Implemented with rounded division so the result is bit-exact with the
# spec's mathematical definition. Naively using floats would lose
# precision; we use integer rounding with floor((2*num + den) // (2*den)).
# -----------------------------------------------------------------------------

def _round_div(num: int, den: int) -> int:
    """floor((num/den) + 1/2)  using only integer ops, banker's-equivalent."""
    return (num + den // 2) // den


def compress(d: int, poly: List[int]) -> List[int]:
    """Compress a polynomial: coeffs in Z_q -> coeffs in [0, 2^d)."""
    two_d = 1 << d
    return [_round_div(two_d * (x % Q), Q) % two_d for x in poly]


def decompress(d: int, poly: List[int]) -> List[int]:
    """Decompress: coeffs in [0, 2^d) -> Z_q.  decompress_d(compress_d(x)) ≈ x."""
    two_d = 1 << d
    return [_round_div(Q * y, two_d) for y in poly]


# -----------------------------------------------------------------------------
# Byte encode / decode  (FIPS 203 §4.2.1, alg 5 and alg 6)
# -----------------------------------------------------------------------------
#
# Packs an array of 256 d-bit unsigned integers into ceil(256*d/8) bytes,
# little-endian within each integer. Used for both raw 12-bit coefficients
# (after NTT) and compressed coefficients (1, 4, 5, 10, or 11 bits).
# -----------------------------------------------------------------------------

def byte_encode(d: int, poly: List[int]) -> bytes:
    """Encode 256 d-bit ints to (32*d) bytes."""
    if len(poly) != N:
        raise ValueError(f"byte_encode expects {N} coeffs, got {len(poly)}")
    bitlen = N * d
    bits = 0
    for i, x in enumerate(poly):
        bits |= (x & ((1 << d) - 1)) << (i * d)
    return bits.to_bytes(bitlen // 8, 'little')


def byte_decode(d: int, data: bytes) -> List[int]:
    """Decode (32*d) bytes back to 256 d-bit ints."""
    expected = 32 * d
    if len(data) != expected:
        raise ValueError(f"byte_decode expects {expected} bytes for d={d}, got {len(data)}")
    bits = int.from_bytes(data, 'little')
    mask = (1 << d) - 1
    # For d = 12 the spec defines byte_decode to reduce mod q; for
    # compressed widths (1/4/5/10/11) it returns raw values that the
    # caller passes to decompress.
    out = [(bits >> (i * d)) & mask for i in range(N)]
    if d == 12:
        out = [x % Q for x in out]
    return out


# -----------------------------------------------------------------------------
# sample_ntt — rejection sampling from a SHAKE128 stream (alg 7)
# -----------------------------------------------------------------------------
#
# Reads 3 bytes at a time, interprets them as two 12-bit values, and accepts
# any value < q. Returns a polynomial in NTT domain. Used to expand the
# public matrix A_hat from rho.
# -----------------------------------------------------------------------------

def sample_ntt(xof) -> List[int]:
    """Rejection-sample 256 coefficients < q from a SHAKE128 stream object."""
    out: List[int] = []
    while len(out) < N:
        chunk = xof.read(3)
        d1 = chunk[0] | ((chunk[1] & 0x0F) << 8)
        d2 = (chunk[1] >> 4) | (chunk[2] << 4)
        if d1 < Q:
            out.append(d1)
            if len(out) == N:
                break
        if d2 < Q:
            out.append(d2)
    return out


# -----------------------------------------------------------------------------
# sample_poly_cbd — Centered Binomial Distribution noise (alg 8)
# -----------------------------------------------------------------------------
#
# Reads 64*eta bytes (= 512*eta bits), packs them in groups of 2*eta bits,
# and computes popcount(first eta bits) - popcount(second eta bits) mod q.
# Result is in {-eta, ..., +eta} mod q.
# -----------------------------------------------------------------------------

def sample_poly_cbd(eta: int, data: bytes) -> List[int]:
    """CBD_eta sampling. eta in {2, 3}. Input must be exactly 64*eta bytes."""
    if eta not in (2, 3):
        raise ValueError(f"sample_poly_cbd unsupported eta={eta}")
    expected = 64 * eta
    if len(data) != expected:
        raise ValueError(f"sample_poly_cbd expects {expected} bytes, got {len(data)}")

    bits = int.from_bytes(data, 'little')
    out: List[int] = []
    for i in range(N):
        # Two eta-bit windows per coefficient
        a_start = 2 * i * eta
        b_start = a_start + eta
        a = (bits >> a_start) & ((1 << eta) - 1)
        b = (bits >> b_start) & ((1 << eta) - 1)
        out.append((bin(a).count('1') - bin(b).count('1')) % Q)
    return out
