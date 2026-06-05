"""
Pure-Python Keccak sponge built on top of `keccak_ref.keccak_f1600`.

Implements the four FIPS 202 functions used by Kyber:

  - SHA3-256  (rate=136B,  domain=0x06, fixed 32B output)
  - SHA3-512  (rate= 72B,  domain=0x06, fixed 64B output)
  - SHAKE-128 (rate=168B,  domain=0x1F, arbitrary output)
  - SHAKE-256 (rate=136B,  domain=0x1F, arbitrary output)

This is the byte-level sponge layer that turns the bare Keccak-f[1600]
permutation (which we have in RTL) into the hash functions Kyber calls.
Used as the Python reference for the upcoming `rtl/sha3_256.sv` and
SHAKE wrappers, cross-validated against `hashlib` in
`tests/test_sponge_ref.py`.

State layout — flat 25-element list of 64-bit lanes, indexed 5*x + y,
matching FIPS 202 §3.2 (and keccak_ref.py). Bytes are absorbed
little-endian within each lane per FIPS 202 §B.1.
"""

from __future__ import annotations
from typing import Optional

from keccak_ref import keccak_f1600

MASK64 = (1 << 64) - 1

# Standard rate/capacity (bytes) per FIPS 202 §6:
#   SHA3-256: rate=136, capacity=64
#   SHA3-512: rate=72,  capacity=128
#   SHAKE128: rate=168, capacity=32
#   SHAKE256: rate=136, capacity=64
RATE_SHA3_256  = 136
RATE_SHA3_512  =  72
RATE_SHAKE_128 = 168
RATE_SHAKE_256 = 136

# Domain separation bytes per FIPS 202 §6.1 / §6.2:
#   SHA3 family : 0x06   (binary suffix 01)
#   SHAKE family: 0x1F   (binary suffix 1111)
DOMAIN_SHA3  = 0x06
DOMAIN_SHAKE = 0x1F


def _absorb(state: list, msg: bytes, rate_bytes: int, domain: int) -> list:
    """Absorb `msg` into `state` with `pad10*1` padding and the supplied
    domain-separation byte. Returns the post-permutation state ready
    for squeezing.

    Algorithm (FIPS 202 §4):
      while len(msg_remaining) >= rate:
        XOR rate bytes into state; permute
      // partial last block (possibly empty)
      block = msg_remaining + domain || 0x00... || 0x80
      XOR block into state; permute
    """
    s = list(state)
    offset = 0
    n = len(msg)

    # Full-rate blocks
    while n - offset >= rate_bytes:
        s = _xor_block_and_permute(s, msg[offset:offset + rate_bytes], rate_bytes)
        offset += rate_bytes

    # Final partial block + padding
    last = bytearray(rate_bytes)
    last[: n - offset] = msg[offset:]
    last[n - offset] ^= domain
    last[rate_bytes - 1] ^= 0x80
    s = _xor_block_and_permute(s, bytes(last), rate_bytes)
    return s


def _lane_idx(i: int) -> int:
    """FIPS 202 §B.1 absorbs the i-th 8-byte block of a rate block into
    lane (x=i%5, y=i//5). Our flat indexing is 5*x + y, so the mapping is
    flat = 5*(i%5) + (i//5)."""
    return 5 * (i % 5) + (i // 5)


def _xor_block_and_permute(state: list, block: bytes, rate_bytes: int) -> list:
    """XOR `rate_bytes` bytes into the state's rate lanes (little-endian)
    in FIPS 202 (x,y)-traversal order, then apply Keccak-f[1600]."""
    assert len(block) == rate_bytes
    s = list(state)
    n_lanes = rate_bytes // 8
    for i in range(n_lanes):
        lane = int.from_bytes(block[i * 8 : (i + 1) * 8], "little")
        s[_lane_idx(i)] ^= lane
    return keccak_f1600(s)


def _squeeze(state: list, rate_bytes: int, outlen: int) -> bytes:
    """Squeeze `outlen` bytes out of `state`, permuting whenever the
    rate portion is exhausted. Lane traversal matches FIPS 202 absorb
    order (x,y) per `_lane_idx`."""
    s = list(state)
    out = bytearray()
    while len(out) < outlen:
        n_lanes = rate_bytes // 8
        for i in range(n_lanes):
            out.extend(s[_lane_idx(i)].to_bytes(8, "little"))
            if len(out) >= outlen:
                break
        if len(out) < outlen:
            s = keccak_f1600(s)
    return bytes(out[:outlen])


def sha3_256(data: bytes) -> bytes:
    """SHA3-256: fixed 32-byte output. FIPS 202 §6.1."""
    state = [0] * 25
    state = _absorb(state, data, RATE_SHA3_256, DOMAIN_SHA3)
    return _squeeze(state, RATE_SHA3_256, 32)


def sha3_512(data: bytes) -> bytes:
    """SHA3-512: fixed 64-byte output. FIPS 202 §6.1."""
    state = [0] * 25
    state = _absorb(state, data, RATE_SHA3_512, DOMAIN_SHA3)
    return _squeeze(state, RATE_SHA3_512, 64)


def shake_128(data: bytes, outlen: int) -> bytes:
    """SHAKE-128: extendable output. FIPS 202 §6.2."""
    state = [0] * 25
    state = _absorb(state, data, RATE_SHAKE_128, DOMAIN_SHAKE)
    return _squeeze(state, RATE_SHAKE_128, outlen)


def shake_256(data: bytes, outlen: int) -> bytes:
    """SHAKE-256: extendable output. FIPS 202 §6.2."""
    state = [0] * 25
    state = _absorb(state, data, RATE_SHAKE_256, DOMAIN_SHAKE)
    return _squeeze(state, RATE_SHAKE_256, outlen)
