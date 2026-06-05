"""
Keccak-f[1600] reference permutation per FIPS 202.

Used as the golden model for rtl/keccak_f1600.sv via tb/test_keccak.py.

This is the permutation only — no sponge / absorb / squeeze / padding.
Those layers (which turn Keccak-f[1600] into SHA3-256, SHAKE128, etc.)
are handled by Python's hashlib in sym.py for the higher-level Kyber
code. The RTL we're verifying is just the 24-round permutation.

State layout matches the FIPS 202 convention: a 5x5 lane grid of 64-bit
lanes indexed lane[x][y] for x, y in [0, 4]. As a flat 25-element array
we use index = 5*x + y.
"""

from __future__ import annotations
from typing import List


# Round constants per FIPS 202 §3.2.5
RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
    0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

# Rotation offsets r[x][y] per FIPS 202 §3.2.2, in flat (5*x+y) order
RHO = [
     0, 36,  3, 41, 18,
     1, 44, 10, 45,  2,
    62,  6, 43, 15, 61,
    28, 55, 25, 21, 56,
    27, 20, 39,  8, 14,
]

MASK64 = (1 << 64) - 1


def _rotl64(x: int, n: int) -> int:
    n %= 64
    return ((x << n) | (x >> (64 - n))) & MASK64


def keccak_round(state: List[int], rc: int) -> List[int]:
    """One round of Keccak-f[1600]: theta -> rho -> pi -> chi -> iota."""
    # theta
    C = [state[5 * x] ^ state[5 * x + 1] ^ state[5 * x + 2] ^
         state[5 * x + 3] ^ state[5 * x + 4] for x in range(5)]
    D = [C[(x + 4) % 5] ^ _rotl64(C[(x + 1) % 5], 1) for x in range(5)]
    a_theta = [(state[5 * x + y] ^ D[x]) & MASK64
               for x in range(5) for y in range(5)]

    # rho + pi: B[y, 2x+3y] = rotl(a_theta[x,y], r[x,y])
    B = [0] * 25
    for x in range(5):
        for y in range(5):
            idx_dst = 5 * y + ((2 * x + 3 * y) % 5)
            B[idx_dst] = _rotl64(a_theta[5 * x + y], RHO[5 * x + y])

    # chi: A''[x,y] = B[x,y] XOR ((~B[x+1,y]) AND B[x+2,y])
    a_chi = [
        (B[5 * x + y] ^ ((~B[5 * ((x + 1) % 5) + y]) & B[5 * ((x + 2) % 5) + y])) & MASK64
        for x in range(5) for y in range(5)
    ]

    # iota: XOR round constant into lane[0,0] only
    a_chi[0] ^= rc
    return a_chi


def keccak_f1600(state: List[int]) -> List[int]:
    """Full 24-round Keccak-f[1600] permutation."""
    assert len(state) == 25
    s = list(state)
    for r in range(24):
        s = keccak_round(s, RC[r])
    return s
